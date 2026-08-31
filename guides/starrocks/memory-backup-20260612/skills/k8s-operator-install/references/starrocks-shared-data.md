# StarRocks Shared-Data (存算分離) — S3/MinIO Storage Volume

> Captured during session with Paul Wong: shared-data StarRocks deployment on K8s with MinIO local object storage and CN auto-scaling.

## Storage Volume Creation (MinIO)

```sql
CREATE STORAGE VOLUME minio_volume
TYPE = S3
LOCATIONS = ("s3://starrocks-data")
PROPERTIES
(
    "enabled" = "true",
    "aws.s3.region" = "us-east-1",
    "aws.s3.endpoint" = "https://minio.luban.paulhome.local:9000",
    "aws.s3.access_key" = "minio",
    "aws.s3.secret_key" = "minio123456789",
    "aws.s3.enable_partitioned_prefix" = "true"
);

SET minio_volume AS DEFAULT STORAGE VOLUME;
```

**Key notes:**
- `TYPE = S3` even for MinIO (MinIO is S3-compatible)
- `aws.s3.region` can be anything — MinIO ignores it
- Use `aws.s3.endpoint` for the MinIO URL
- If HTTP (non-TLS), strip `https://` prefix
- Bucket must exist before StarRocks writes to it

## Storage Volume Creation (AWS S3)

```sql
CREATE STORAGE VOLUME def_volume
TYPE = S3
LOCATIONS = ("s3://defaultbucket")
PROPERTIES
(
    "enabled" = "true",
    "aws.s3.region" = "us-west-2",
    "aws.s3.endpoint" = "https://s3.us-west-2.amazonaws.com",
    "aws.s3.use_aws_sdk_default_behavior" = "false",
    "aws.s3.use_instance_profile" = "false",
    "aws.s3.access_key" = "xxxxxxxxxx",
    "aws.s3.secret_key" = "yyyyyyyyyy",
    "aws.s3.enable_partitioned_prefix" = "true"
);

SET def_volume AS DEFAULT STORAGE VOLUME;
```

## GCS Storage Volume

```sql
CREATE STORAGE VOLUME def_volume
TYPE = GS
LOCATIONS = ("gs://defaultbucket")
PROPERTIES
(
    "enabled" = "true",
    "gcp.gcs.use_compute_engine_service_account" = "false",
    "gcp.gcs.service_account_email" = "<email>",
    "gcp.gcs.service_account_private_key_id" = "<key_id>",
    "gcp.gcs.service_account_private_key" = "<private_key>"
);

SET def_volume AS DEFAULT STORAGE VOLUME;
```

## FE Config for Shared-Data Mode

The Operator uses a ConfigMap to inject FE config. The key setting:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: starrocks-fe-cm
data:
  fe.conf: |
    run_mode = shared_data
    meta_dir = /opt/starrocks/fe/meta
    cloud_native_meta_port = 6090
```

In the StarRocksCluster CR, reference it:

```yaml
starRocksFeSpec:
  configMapInfo:
    configMapName: starrocks-fe-cm
    resolveKey: fe.conf
```

## FE + CN Architecture vs FE + BE (Shared-Nothing)

| Feature | Shared-Nothing (FE+BE) | Shared-Data (FE+CN) |
|---------|----------------------|---------------------|
| Data storage | On BE local disk | Remote S3/MinIO |
| Query execution | BE handles it | CN handles it |
| CN/HPA scaling | Not available | ✅ Supported |
| Data migration on scale | Required (tablet shuffle) | Not needed |
| Local cache | N/A | CN has local disk cache |
| Best for | On-prem, simple setup | Cloud, elastic scaling |

## Pitfalls

- **Only CN nodes in shared-data mode** — do NOT add BE nodes to a shared-data cluster (unknown behavior)
- **CN without storageVolumes** — if CN pods scale up/down on demand, they may have no PVC attached. Set `storageVolumes: []` for no-cache mode
- **MinIO bucket must pre-exist** — StarRocks won't create it automatically
- **Partitioned prefix recommended** — `"aws.s3.enable_partitioned_prefix" = "true"` improves query performance
