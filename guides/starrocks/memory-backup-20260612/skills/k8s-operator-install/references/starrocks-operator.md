# StarRocks Kubernetes Operator — Quick Reference

> Source: [StarRocks docs v4.1](https://docs.starrocks.io/docs/deployment/sr_operator/) + [operator repo](https://github.com/StarRocks/starrocks-kubernetes-operator)

## CRD

```bash
kubectl apply -f https://raw.githubusercontent.com/StarRocks/starrocks-kubernetes-operator/main/deploy/starrocks.com_starrocksclusters.yaml
```

## Operator Deployment

```bash
kubectl apply -f https://raw.githubusercontent.com/StarRocks/starrocks-kubernetes-operator/main/deploy/operator.yaml
kubectl -n starrocks get pods
```

## Minimal CR (FE + BE)

```yaml
apiVersion: starrocks.com/v1
kind: StarRocksCluster
metadata:
  name: starrockscluster-sample
  namespace: starrocks
spec:
  starRocksFeSpec:
    image: starrocks/fe-ubuntu:latest
    replicas: 3
    limits:  { cpu: 4, memory: 8Gi }
    requests: { cpu: 4, memory: 8Gi }
    storageVolumes:
    - name: fe-meta; storageSize: 10Gi; mountPath: /opt/starrocks/fe/meta
    - name: fe-log;  storageSize: 5Gi;  mountPath: /opt/starrocks/fe/log
  starRocksBeSpec:
    image: starrocks/be-ubuntu:latest
    replicas: 3
    limits:  { cpu: 4, memory: 8Gi }
    requests: { cpu: 4, memory: 8Gi }
    storageVolumes:
    - name: be-data; storageSize: 1Ti;  mountPath: /opt/starrocks/be/storage
    - name: be-log;  storageSize: 1Gi;  mountPath: /opt/starrocks/be/log
```

## CN Auto-Scaling

```yaml
starRocksCnSpec:
  autoScalingPolicy:
    maxReplicas: 10
    minReplicas: 1
    hpaPolicy:
      metrics:
        - type: Resource
          resource:
            name: memory
            target:
              averageUtilization: 60
              type: Utilization
        - type: Resource
          resource:
            name: cpu
            target:
              averageUtilization: 60
              type: Utilization
      behavior:
        scaleUp:
          policies:
            - type: Pods
              value: 1
              periodSeconds: 10
        scaleDown:
          selectPolicy: Disabled
```

## Management

| Action | Command |
|--------|---------|
| Upgrade BE | `kubectl patch starrockscluster \<name\> --type=merge -p '{\"spec\":{\"starRocksBeSpec\":{\"image\":\"starrocks/be-ubuntu:latest\"}}}'` |
| Upgrade FE | `kubectl patch starrockscluster \<name\> --type=merge -p '{\"spec\":{\"starRocksFeSpec\":{\"image\":\"starrocks/fe-ubuntu:latest\"}}}'` |
| Scale BE | `kubectl patch starrockscluster \<name\> --type=merge -p '{\"spec\":{\"starRocksBeSpec\":{\"replicas\":N}}}'` |
| Scale FE | `kubectl patch starrockscluster \<name\> --type=merge -p '{\"spec\":{\"starRocksFeSpec\":{\"replicas\":N}}}'` |
| Connect | `mysql -h \<FE-SVC-IP\> -P 9030 -uroot` |

## Key Patterns

- **CRD annotation limit** (>262KB): use `kubectl create -f` (first install) or `kubectl replace -f` (update).
- **Storage**: omit `storageVolumes` for ephemeral (emptyDir); specify for persistent.
- **Access**: default is ClusterIP; change to LoadBalancer or NodePort via `edit src starrockscluster-sample`.
- **CN autoscaling**: remove `replicas` field when `autoScalingPolicy` is set.
- **BE scale-in**: wait for tablet redistribution (check `SHOW PROC '/statistic'`) before proceeding.
