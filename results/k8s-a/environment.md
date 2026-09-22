# Environment — k8s-a, measured 2026-09-22T22:57:14+02:00

## Client
    Client Version: v1.36.4
    Kustomize Version: v5.8.1
    Server Version: v1.36.4+k3s1

## Nodes
    NAME     STATUS   ROLES                AGE    VERSION        INTERNAL-IP       EXTERNAL-IP   OS-IMAGE                       KERNEL-VERSION                  CONTAINER-RUNTIME
    k8s-a1   Ready    control-plane,etcd   166d   v1.36.4+k3s1   <redacted-lan-ip>   <none>        Debian GNU/Linux 13 (trixie)   6.12.74+deb13+1-amd64 (amd64)   containerd://2.3.4-k3s1.36
    k8s-a2   Ready    control-plane,etcd   166d   v1.36.4+k3s1   <redacted-lan-ip>   <none>        Debian GNU/Linux 13 (trixie)   6.12.74+deb13+1-amd64 (amd64)   containerd://2.3.4-k3s1.36
    k8s-a3   Ready    control-plane,etcd   166d   v1.36.4+k3s1   <redacted-lan-ip>   <none>        Debian GNU/Linux 13 (trixie)   6.12.74+deb13+1-amd64 (amd64)   containerd://2.3.4-k3s1.36

## Endpoint
    https://k8s-a.<internal-domain>:6443

## Payload pod
    NAME      READY   STATUS    RESTARTS   AGE    IP           NODE     NOMINATED NODE   READINESS GATES
    payload   1/1     Running   0          135m   10.42.0.55   k8s-a1   <none>           <none>

## Note

    LAN addresses and the internal FQDN are redacted. The error text, byte counts
    and digests are not.
