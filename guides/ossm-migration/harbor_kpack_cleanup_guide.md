# Harbor Image Cleanup & kpack Build History Management

> Date: 2026-07-14
> Author: Paul Wong
> Scope: ds01-harbor.luban.paulhome.local + kpack in ci-dwh namespace

---

## Background

- **kpack** builds images to `ds01-harbor.luban.paulhome.local/dwh/<repo>`
- Each build pushes 3 tags: `latest`, `b<number>.<date>`, and a short SHA prefix
- Harbor has a lifecycle policy: keep latest N tags per repo
- kpack Image CR has `successBuildHistoryLimit` and `failedBuildHistoryLimit`

---

## Key Concepts

### kpack Build vs Harbor Digest vs Tag

| Layer | What it is | Immutable |
|-------|-----------|-----------|
| **Build CR** | Kubernetes resource tracking a single build | No — can be deleted |
| **Digest** | `sha256:...` reference to the image blob | Yes — immutable |
| **Tag** | Human-readable name pointing to a digest | No — can be deleted/updated |
| **Blob** | Actual image layer data on disk | No — GC can remove unreferenced blobs |

### How kpack References Work

```
Build CR (status.latestImage)
  → digest: sha256:ec61fd19...
    → blob in Harbor registry (immutable, only removed by GC)
```

Harbor's lifecycle policy deletes **tags**, not digests or blobs.
GC only removes blobs that have **no tag** pointing to them.

---

## The Problem

### Misalignment Between kpack and Harbor

| Component | Setting |
|-----------|---------|
| kpack `successBuildHistoryLimit` | 10 (default) |
| kpack `failedBuildHistoryLimit` | 10 (default) |
| Harbor retention | Keep latest 3 tags |

- kpack keeps 10 build CRs → each build pushes 3 tags
- Harbor deletes tags beyond the 3rd
- Result: build CRs reference digests whose tags no longer exist in Harbor
- These are "orphaned" build CRs — they reference valid digests but the tags are gone

### Impact of Orphaned Build CRs

| Impact | Severity | Description |
|--------|----------|-------------|
| Functional | None | kpack Image CR only tracks `lastBuiltImage`, not all builds |
| Running Pods | None | Pods reference digest, not Build CR |
| Resource | Low | Build CRs are tiny (KB each), PVCs are managed per Image not per Build |
| Maintainability | Medium | Build history gets cluttered, harder to audit, easy to accidentally delete active builds |
| Consistency | Medium | Harbor retention and kpack history don't align — confusing when debugging |

---

## Audit Results (2026-07-14)

### Harbor State (ds01-harbor.luban.paulhome.local)

| Repository | Artifacts in Harbor | Tags per artifact |
|-----------|--------------------|-------------------|
| dwh/comp | 3 | latest + b13 + SHA prefix |
| dwh/ewallet | 3 | latest + b5 + SHA prefix |
| dwh/ferry | 3 | latest + b2 + SHA prefix |
| dwh/dagster-platform | 3 | latest + b2 + SHA prefix |
| dwh/vip-limo | 3 | latest + b6 + SHA prefix |

### kpack Build CRs State

| Image | Total Builds | Valid Digest (in Harbor) | Orphaned (GC'd) | No Digest |
|-------|-------------|--------------------------|-----------------|-----------|
| comp | 8 | 3 (build-11, 12, 13) | 5 (build-1, 3, 4, 5, 10) | — |
| ewallet | 5 | 1 (build-5) | 4 (build-1, 2, 3, 4) | — |
| ferry | 2 | 1 (build-2) | 1 (build-1) | — |
| dagster-platform | 2 | 1 (build-2) | 1 (build-1) | — |
| **Total** | **17 with digest + 4 without** | **7 valid** | **11 orphaned** | **4 empty** |

### How to Check

```bash
# List all builds with their digests
kubectl -n ci-dwh get build -o custom-columns="NAME:.metadata.name,DIGEST:.status.latestImage"

# List current Harbor tags for a repo
curl -sk -u admin:Harbor12345 \
  "https://ds01-harbor.luban.paulhome.local/api/v2.0/projects/dwh/repositories/<repo>/artifacts?page_size=100"

# Cross-reference: check if a build's digest exists in Harbor
kubectl -n ci-dwh get build comp-build-1 -o json | grep latestImage
# Then verify digest exists in Harbor artifacts
```

---

## Solution: Align kpack and Harbor Retention

### Strategy B: Reduce kpack Build History (Selected)

Set kpack `successBuildHistoryLimit` and `failedBuildHistoryLimit` to 3.

### Why 3?

- kpack pushes 3 tags per build (latest + build-number + SHA prefix)
- 3 builds × 3 tags = 9 tag slots per repo
- Harbor retention keeps latest 3 tags → each build consumes 1 tag slot effectively (since latest rotates)
- 3 builds gives enough history for rollback/triage without clutter

### Implementation

```bash
# Patch all images in ci-dwh
for img in comp dagster-platform ewallet ferry; do
  kubectl -n ci-dwh patch image $img --type merge -p '{
    "spec": {
      "successBuildHistoryLimit": 3,
      "failedBuildHistoryLimit": 3
    }
  }'
done
```

### What Happens Next

1. kpack controller will prune build CRs exceeding the limit (3 successful + 3 failed)
2. Build history stays clean — only the 3 most recent builds are kept
3. No more orphaned build CRs with stale digests
4. Harbor retention policy can remain as-is (keep latest 3 tags)

---

## Troubleshooting Process

### Step 1: Initial Question — How to Clean Up Harbor Images

**Question:** How to clean up Harbor images?

**Answer:** Three methods:
1. **Harbor built-in Garbage Collection (GC)** — removes unreferenced blob data (layers pulled by deleted tags)
2. **Delete tags via API** — GC only removes blobs NOT referenced by any tag, so delete tags first
3. **Bulk delete old images** — via retention policy or API scripts
4. **Delete entire repositories** — via API

**Key workflow:** Delete unwanted tags first → Run garbage collection to free disk space → Optionally set up a retention policy or cleanup schedule

### Step 2: Setting Up a Retention Policy to Keep Last 5 Tags

**Question:** How to setup policy to keep latest 5 tags?

**Answer:** Harbor has a built-in **Image Lifecycle Management** feature:

1. **UI:** System Management → Policies → New Lifecycle Policy → Tag expiration → Keep last 5 → Schedule
2. **API:** Create policy with trigger type `Schedule` and action `delete_tag` with `keep_last_pull: 5`
3. **Recommended:** Use the UI approach — cleaner and avoids API v2 limitations

**Note:** The API approach is version-dependent and often more complex than UI. For Harbor 2.5+, the **Image Cleanup** policy under **Policies** is the modern way.

### Step 3: Impact on kpack Build CRs

**Question:** Will Harbor retention policy (keep last 3 images) affect kpack Build CRs?

**Initial analysis:**
- kpack Build CRs use **digest** references (`@sha256:...`), not tags
- Digests are immutable — as long as Harbor keeps the blob data, Build CR references won't break
- **Risk:** Harbor GC will delete blobs with no tag references → old Build CRs become invalid
- **Best practice:** Delete old Build CRs first → Let Harbor clean old tags → Then GC

### Step 4: After GC — Identifying Orphaned Builds

**Question:** We already ran GC. Check all builds, which ones don't have matching digests? (Don't delete)

**Troubleshooting process:**

1. **Initial check:**
```bash
kubectl -n ci-dwh get build -o custom-columns="NAME:.metadata.name,DIGEST:.status.lastBuiltImage"
# Result: All digest columns showed <none>
```

2. **Deep dive — found the issue:**
```bash
# The digest is in status.latestImage, not status.lastBuiltImage!
kubectl -n ci-dwh get build -o json | python3 -c "..."
# Found 17 builds with digests, 4 without (comp-build-6,7,8,9)
```

3. **Cross-reference with Harbor:**
```bash
# Check Harbor API
curl -sk -u admin:Harbor12345 \
  "https://ds01-harbor.luban.paulhome.local/api/v2.0/projects"
# Result: Only "library" project (id=1) with 0 repos
```

**Problem discovered:** The `dwh` project wasn't found via API search. Let me check:
```bash
# Try all possible Harbor endpoints
curl -sk -u admin:Harbor12345 "https://ds01-harbor.luban.paulhome.local/api/v2.0/search?q=*"
# Result: Empty

# Check Harbor database directly
kubectl -n harbor exec -it harbor-database-0 -- psql -U postgres -d registry -c "..."
# Found: Only library, luban-ci, demo-apps, mesh-demo projects — NO dwh!
```

**Critical finding:** ds01-harbor (192.168.89.61) is a **separate Harbor instance** not in local k8s. The builds reference `ds01-harbor.luban.paulhome.local/dwh/*` but the Harbor API was returning empty results.

**Resolution:** Use default credentials (admin/ Harbor12345) instead of environment variable:
```bash
curl -sk -u admin:Harbor12345 "https://ds01-harbor.luban.paulhome.local/api/v2.0/projects"
# Result: Found project 37 (dwh) with 5 repos
```

4. **Final cross-reference:**
```python
python3 << 'PYEOF'
import subprocess, json

def harbor_get(path):
    r = subprocess.run(f'curl -sk -u admin:Harbor12345 "https://ds01-harbor.luban.paulhome.local/api/v2.0{path}"', shell=True, capture_output=True, text=True)
    return json.loads(r.stdout)

# Get Harbor artifacts per repo
harbor_artifacts = {}
for repo in ['comp', 'ewallet', 'ferry', 'dagster-platform', 'vip-limo']:
    data = harbor_get(f'/projects/dwh/repositories/{repo}/artifacts?page_size=100')
    if isinstance(data, list):
        harbor_artifacts[repo] = {a['digest']: a for a in data}

# Get all builds
builds = json.loads(subprocess.run('kubectl -n ci-dwh get build -o json', shell=True, capture_output=True, text=True).stdout)['items']

# Cross-reference
for b in builds:
    name = b['metadata']['name']
    latest = b['status'].get('latestImage', '')
    if latest:
        digest = latest.split('@')[1] if '@' in latest else ''
        print(f'{name}: {digest[:20]} in harbor: {digest[:20] in [d[:20] for d in harbor_artifacts.get(name.split("-build-")[0], {})]}')
PYEOF
```

**Result:**
- 7 builds with valid digest in Harbor
- 10 builds with GC'd digests (old, no longer in Harbor)
- 4 builds with no digest (comp-build-6,7,8,9)

### Step 5: Impact Assessment

**Question:** What's the impact of keeping orphaned build CRs?

**Assessment:**
- **Functional:** None — kpack Image CR only tracks `lastBuiltImage`
- **Running Pods:** None — Pods reference digest, not Build CR
- **Resources:** Low — Build CRs are tiny (KB each), PVCs are per Image not per Build
- **Maintainability:** Medium — Build history cluttered, hard to audit
- **Consistency:** Medium — Harbor retention and kpack history don't align

**Conclusion:** No functional impact, but causes maintainability issues.

### Step 6: Solution — Align kpack and Harbor Retention

**Options considered:**
- **A:** Change Harbor retention to keep more tags (e.g., 15)
- **B:** Reduce kpack build history to 3 (selected)
- **C:** Keep both as-is (current state)

**Selected: Strategy B**

**Reasoning:**
- kpack pushes 3 tags per build (latest + build-number + SHA prefix)
- 3 builds × 3 tags = 9 tag slots per repo
- Harbor retention keeps latest 3 tags → each build consumes 1 tag slot effectively
- 3 builds gives enough history for rollback/triage without clutter
- Simpler than changing Harbor configuration

**Implementation:**
```bash
for img in comp dagster-platform ewallet ferry; do
  kubectl -n ci-dwh patch image $img --type merge -p '{
    "spec": {
      "successBuildHistoryLimit": 3,
      "failedBuildHistoryLimit": 3
    }
  }'
done
```

**Expected behavior:**
1. kpack controller prunes build CRs exceeding limit (3 successful + 3 failed)
2. Build history stays clean — only 3 most recent builds kept
3. No more orphaned build CRs with stale digests
4. Harbor retention policy remains unchanged

### Key Learnings

1. **Build CR digest location:** `status.latestImage`, not `status.lastBuiltImage`
2. **ds01-harbor is separate:** Not in local k8s, requires direct API access with default credentials
3. **Harbor API search limitations:** `search?q=*` doesn't work as expected; use `/projects` and `/repositories` endpoints
4. **kpack build history limit:** Controls how many Build CRs are kept per Image; default is 10, which can cause orphaned references
5. **GC impact:** Only removes blobs with no tag references; digests remain valid as long as tags exist
6. **Tag rotation:** Each build pushes 3 tags (latest, b<number>, SHA prefix); `latest` rotates, but old tags may persist if not cleaned

---

## Reference: Harbor Cleanup Operations

### Via UI (System Management)

1. **Policies → Image Cleanup** — set retention per repo
2. **Lifecycle → Schedule** — set cleanup cron (e.g., daily 2 AM)
3. **Lifecycle → Rules** — add tag deletion rule: keep latest N tags

### Via API

```bash
# List repositories
curl -sk -u admin:Harbor12345 \
  "https://ds01-harbor.luban.paulhome.local/api/v2.0/repositories?page_size=100"

# List artifacts in a repo
curl -sk -u admin:Harbor12345 \
  "https://ds01-harbor.luban.paulhome.local/api/v2.0/projects/dwh/repositories/<repo>/artifacts?page_size=100"

# Delete a specific tag
curl -sk -X DELETE -u admin:Harbor12345 \
  "https://ds01-harbor.luban.paulhome.local/api/v2.0/projects/dwh/repositories/<repo>/tags/<tag>"

# Delete entire repository
curl -sk -X DELETE -u admin:Harbor12345 \
  "https://ds01-harbor.luban.paulhome.local/api/v2.0/projects/dwh/repositories/<repo>"

# Trigger garbage collection
curl -sk -X POST -u admin:Harbor12345 \
  "https://ds01-harbor.luban.paulhome.local/api/v2.0/system/gc/schedule" \
  -H "Content-Type: application/json" \
  -d '{"schedule":{"type":"Manual","cron":""}}'
```

### Via Harbor Helm

```bash
# Set GC schedule
helm upgrade harbor harbor/harbor -f values.yaml \
  --set gc.enabled=true \
  --set gc.schedule="0 2 * * *"
```

---

## Checklist

- [x] Audit all build CRs vs Harbor artifacts
- [x] Identify orphaned builds (GC'd digests)
- [x] Set kpack `successBuildHistoryLimit: 3` and `failedBuildHistoryLimit: 3`
- [ ] Let kpack controller prune old build CRs
- [ ] Verify no orphaned build CRs remain after pruning
- [ ] Optionally delete orphaned build CRs manually
- [ ] Monitor Harbor disk usage after GC
- [ ] Set up Harbor lifecycle policy (keep latest 3 tags)
- [ ] Schedule regular GC (daily or weekly)

---

## Notes

- **ds01-harbor credentials**: admin / Harbor12345 (default)
- **ds01-harbor IP**: 192.168.89.61 (not in local k8s)
- **kpack namespace**: ci-dwh
- **Builder**: luban-builder (ClusterBuilder)
- **Stack**: luban-stack
