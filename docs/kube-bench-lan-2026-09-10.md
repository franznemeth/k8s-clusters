# kube-bench — lan cluster — 2026-09-10

CIS Kubernetes Benchmark scan of the `lan` cluster.

| | |
|---|---|
| Cluster | `lan` (ceres.lan control-plane; deimos/pallas/nas workers) |
| Kubernetes | API server v1.35.4, kubelets v1.34.1 |
| Benchmark | CIS Kubernetes Benchmark v1.11 (kube-bench auto-detected, newest bundled) |
| Tool | `docker.io/aquasec/kube-bench@sha256:75506f222d1eb6ce2a751a5533bdc0a3b54c898e2e49e7751d0ee22cfb862679` (`:latest` on 2026-09-10) |
| How | two throwaway in-cluster Jobs in ns `kube-bench` (privileged, hostPath). Master job on `ceres.lan` targeting `master,etcd,controlplane,policies`; node job on `deimos.lan` targeting `node,policies`. Namespace deleted after. |

## Totals

| Target (where) | PASS | FAIL | WARN |
|---|---:|---:|---:|
| master — ceres.lan | 46 | 9 | 5 |
| etcd — ceres.lan | 7 | 0 | 0 |
| controlplane — ceres.lan | 0 | 0 | 5 |
| node — deimos.lan | 19 | 1 | 5 |
| policies (section 5, ran in **both** jobs) | 0 | 0 | 34 (unique) |

**Unique: 10 FAIL, ~49 WARN, 72 PASS.** Section 5 (`policies`) is all "Manual"
checks and was counted once in each job — the raw `== Summary total ==` lines
(9 FAIL / 44 WARN master, 1 FAIL / 39 WARN node) double-count it.

Nothing here is an active compromise. The FAILs are mostly missing API audit
logging + two `--bind-address` settings the `core` inventory already has but `lan`
doesn't; the WARNs are dominated by "you have no Pod Security Admission / no
NetworkPolicies / review your RBAC".

---

## FAIL — fix via `inventory/group_vars/all.yml` (Kubespray)

These are one-line Kubespray settings; `core`'s `group_vars/all.yml` already has
the last two.

| ID | Check | Fix |
|---|---|---|
| 1.3.7 | kube-controller-manager `--bind-address` should be `127.0.0.1` | add `kube_controller_manager_bind_address: 127.0.0.1` (core already sets this) |
| 1.4.2 | kube-scheduler `--bind-address` should be `127.0.0.1` | add `kube_scheduler_bind_address: 127.0.0.1` + `kube_kubeadm_scheduler_extra_args: {bind-address: 127.0.0.1}` (core already sets this) |
| 1.2.16–1.2.19 | API server audit log not configured (`--audit-log-path`, `--audit-log-maxage/maxbackup/maxsize`) | set `kubernetes_audit: true` (core has it `true`, lan has it `false`). Pulls in an audit policy + the four flags. Also clears WARN 3.2.1 / 3.2.2. |
| 1.2.30 | `--service-account-extend-token-expiration` should be `false` | `kube_apiserver_extra_args: {service-account-extend-token-expiration: "false"}` — only if nothing still relies on legacy (>1y) SA tokens |

Then `./deploy.sh inventory cluster.yml` (or `--limit` the control-plane node).

## FAIL — host-level, low value on this cluster

| ID | Check | Note |
|---|---|---|
| 1.1.12 | etcd data dir `/var/lib/etcd` not owned `etcd:etcd` | Expected with `etcd_deployment_type: kubeadm` — etcd runs as a static pod (root), there is no host `etcd` user. CIS assumes host-installed etcd. Leave it, or `chown` and expect kubeadm to not care. |
| 1.1.19 | `/etc/kubernetes/pki` dir/files not all `root:root` | Permissions are already correct (600/644); only ownership on some entries differs. `ssh ceres.lan 'sudo chown -R root:root /etc/kubernetes/pki'` if you want it clean. |
| 4.3.1 (node) | kube-proxy metrics service not bound to localhost | **Not applicable** — `kube_proxy_remove: true`, Cilium does kube-proxy replacement. kube-bench matched a leftover kube-proxy config artifact. Ignore. |

## WARN — worth a decision (not "Manual/verify" noise)

| ID | Check | Note |
|---|---|---|
| 1.2.1 | API server `--anonymous-auth=false` | `group_vars/all.yml` has `#kube_api_anonymous_auth: false` commented. Safe to enable on modern k8s (health probes use a separate path). |
| 1.2.3 | admission plugin `DenyServiceExternalIPs` not enabled | Add to `kube_apiserver_enable_admission_plugins` if you never use `Service.spec.externalIPs`. |
| 1.1.9 / 1.1.10 | CNI file perms/ownership under `/etc/cni/net.d` (Manual) | `ssh <node> 'sudo ls -la /etc/cni/net.d'` — likely already fine (Cilium-managed). |
| 4.2.9 (node) | kubelet `--tls-cert-file` / `--tls-private-key-file` not set (Manual) | Expected — `kubelet_rotate_server_certificates: true`, kubelet uses rotated serving certs. This is the better setup; WARN is informational. |
| 4.2.7 (node) | kubelet `--hostname-override` is set (Manual) | Standard Kubespray behaviour (node name). Benign. |
| 4.2.12 (node) | kubelet strong TLS ciphers (Manual) | `tls_cipher_suites` in group_vars is for the API server. Add `kubelet_tls_cipher_suites` with the same list to also pin the kubelet. |
| 4.1.3 / 4.1.4 (node) | `proxy.conf` perms/ownership (Manual) | kube-proxy removed → file shouldn't exist. N/A. |

## WARN — section 5 "Policies" (34 Manual checks, hardening backlog)

All require manual review / new objects, none are single commands. The
substantive gaps on a default Kubespray + Cilium cluster:

- **5.2.1 — no active Pod Security policy mechanism.** No Pod Security Admission
  labels on namespaces and no external policy engine (Kyverno/Gatekeeper). This
  is the single biggest item — 5.2.2–5.2.12 (privileged / hostPID / hostNetwork /
  runAsRoot / NET_RAW / hostPath / …) all follow from it. Consider enabling PSA
  (`baseline`/`restricted`) per namespace, or Kyverno.
- **5.3.2 — no NetworkPolicies.** Cilium supports them (5.3.1), but no namespace
  defines a default-deny. Add default-deny + per-app allow policies.
- **5.1.x — RBAC review.** cluster-admin usage, wildcard verbs/resources,
  `system:masters`, access to `secrets` / `pods/exec` / `certificatesigningrequests/approval`
  / webhook configs. Manual audit; `kubectl get clusterrolebindings -o wide` is
  the starting point.
- 5.4.1 / 5.4.2 — prefer secret *files* over env vars; consider external secret
  storage (Vault is already in the estate).
- 5.6.2 / 5.6.3 — set `seccompProfile: RuntimeDefault` and non-root
  `securityContext` on workloads. Note `kubelet_seccomp_default: true` is already
  set cluster-wide, which covers pods that don't specify one.
- 5.6.4 — don't use the `default` namespace for workloads.

---

## Appendix A — master job raw output (ceres.lan, targets: master,etcd,controlplane,policies)

```text
[INFO] 1 Control Plane Security Configuration
[INFO] 1.1 Control Plane Node Configuration Files
[PASS] 1.1.1 Ensure that the API server pod specification file permissions are set to 600 or more restrictive (Automated)
[PASS] 1.1.2 Ensure that the API server pod specification file ownership is set to root:root (Automated)
[PASS] 1.1.3 Ensure that the controller manager pod specification file permissions are set to 600 or more restrictive (Automated)
[PASS] 1.1.4 Ensure that the controller manager pod specification file ownership is set to root:root (Automated)
[PASS] 1.1.5 Ensure that the scheduler pod specification file permissions are set to 600 or more restrictive (Automated)
[PASS] 1.1.6 Ensure that the scheduler pod specification file ownership is set to root:root (Automated)
[PASS] 1.1.7 Ensure that the etcd pod specification file permissions are set to 600 or more restrictive (Automated)
[PASS] 1.1.8 Ensure that the etcd pod specification file ownership is set to root:root (Automated)
[WARN] 1.1.9 Ensure that the Container Network Interface file permissions are set to 600 or more restrictive (Manual)
[WARN] 1.1.10 Ensure that the Container Network Interface file ownership is set to root:root (Manual)
[PASS] 1.1.11 Ensure that the etcd data directory permissions are set to 700 or more restrictive (Automated)
[FAIL] 1.1.12 Ensure that the etcd data directory ownership is set to etcd:etcd (Automated)
[PASS] 1.1.13 Ensure that the default administrative credential file permissions are set to 600 (Automated)
[PASS] 1.1.14 Ensure that the default administrative credential file ownership is set to root:root (Automated)
[PASS] 1.1.15 Ensure that the scheduler.conf file permissions are set to 600 or more restrictive (Automated)
[PASS] 1.1.16 Ensure that the scheduler.conf file ownership is set to root:root (Automated)
[PASS] 1.1.17 Ensure that the controller-manager.conf file permissions are set to 600 or more restrictive (Automated)
[PASS] 1.1.18 Ensure that the controller-manager.conf file ownership is set to root:root (Automated)
[FAIL] 1.1.19 Ensure that the Kubernetes PKI directory and file ownership is set to root:root (Automated)
[PASS] 1.1.20 Ensure that the Kubernetes PKI certificate file permissions are set to 644 or more restrictive (Manual)
[PASS] 1.1.21 Ensure that the Kubernetes PKI key file permissions are set to 600 (Manual)
[INFO] 1.2 API Server
[WARN] 1.2.1 Ensure that the --anonymous-auth argument is set to false (Manual)
[PASS] 1.2.2 Ensure that the --token-auth-file parameter is not set (Automated)
[WARN] 1.2.3 Ensure that the --DenyServiceExternalIPs is set (Manual)
[PASS] 1.2.4 Ensure that the --kubelet-client-certificate and --kubelet-client-key arguments are set as appropriate (Automated)
[PASS] 1.2.5 Ensure that the --kubelet-certificate-authority argument is set as appropriate (Automated)
[PASS] 1.2.6 Ensure that the --authorization-mode argument is not set to AlwaysAllow (Automated)
[PASS] 1.2.7 Ensure that the --authorization-mode argument includes Node (Automated)
[PASS] 1.2.8 Ensure that the --authorization-mode argument includes RBAC (Automated)
[PASS] 1.2.9 Ensure that the admission control plugin EventRateLimit is set (Manual)
[PASS] 1.2.10 Ensure that the admission control plugin AlwaysAdmit is not set (Automated)
[PASS] 1.2.11 Ensure that the admission control plugin AlwaysPullImages is set (Manual)
[PASS] 1.2.12 Ensure that the admission control plugin ServiceAccount is set (Automated)
[PASS] 1.2.13 Ensure that the admission control plugin NamespaceLifecycle is set (Automated)
[PASS] 1.2.14 Ensure that the admission control plugin NodeRestriction is set (Automated)
[PASS] 1.2.15 Ensure that the --profiling argument is set to false (Automated)
[FAIL] 1.2.16 Ensure that the --audit-log-path argument is set (Automated)
[FAIL] 1.2.17 Ensure that the --audit-log-maxage argument is set to 30 or as appropriate (Automated)
[FAIL] 1.2.18 Ensure that the --audit-log-maxbackup argument is set to 10 or as appropriate (Automated)
[FAIL] 1.2.19 Ensure that the --audit-log-maxsize argument is set to 100 or as appropriate (Automated)
[WARN] 1.2.20 Ensure that the --request-timeout argument is set as appropriate (Manual)
[PASS] 1.2.21 Ensure that the --service-account-lookup argument is set to true (Automated)
[PASS] 1.2.22 Ensure that the --service-account-key-file argument is set as appropriate (Automated)
[PASS] 1.2.23 Ensure that the --etcd-certfile and --etcd-keyfile arguments are set as appropriate (Automated)
[PASS] 1.2.24 Ensure that the --tls-cert-file and --tls-private-key-file arguments are set as appropriate (Automated)
[PASS] 1.2.25 Ensure that the --client-ca-file argument is set as appropriate (Automated)
[PASS] 1.2.26 Ensure that the --etcd-cafile argument is set as appropriate (Automated)
[PASS] 1.2.27 Ensure that the --encryption-provider-config argument is set as appropriate (Manual)
[PASS] 1.2.28 Ensure that encryption providers are appropriately configured (Manual)
[PASS] 1.2.29 Ensure that the API Server only makes use of Strong Cryptographic Ciphers (Manual)
[FAIL] 1.2.30 Ensure that the --service-account-extend-token-expiration parameter is set to false (Automated)
[INFO] 1.3 Controller Manager
[PASS] 1.3.1 Ensure that the --terminated-pod-gc-threshold argument is set as appropriate (Manual)
[PASS] 1.3.2 Ensure that the --profiling argument is set to false (Automated)
[PASS] 1.3.3 Ensure that the --use-service-account-credentials argument is set to true (Automated)
[PASS] 1.3.4 Ensure that the --service-account-private-key-file argument is set as appropriate (Automated)
[PASS] 1.3.5 Ensure that the --root-ca-file argument is set as appropriate (Automated)
[PASS] 1.3.6 Ensure that the RotateKubeletServerCertificate argument is set to true (Automated)
[FAIL] 1.3.7 Ensure that the --bind-address argument is set to 127.0.0.1 (Automated)
[INFO] 1.4 Scheduler
[PASS] 1.4.1 Ensure that the --profiling argument is set to false (Automated)
[FAIL] 1.4.2 Ensure that the --bind-address argument is set to 127.0.0.1 (Automated)

== Remediations master ==
1.1.9 Run the below command (based on the file location on your system) on the control plane node.
For example, chmod 600 <path/to/cni/files>

1.1.10 Run the below command (based on the file location on your system) on the control plane node.
For example,
chown root:root <path/to/cni/files>

1.1.12 On the etcd server node, get the etcd data directory, passed as an argument --data-dir,
from the command 'ps -ef | grep etcd'.
Run the below command (based on the etcd data directory found above).
For example, chown etcd:etcd /var/lib/etcd

1.1.19 Run the below command (based on the file location on your system) on the control plane node.
For example,
chown -R root:root /etc/kubernetes/pki/

1.2.1 Edit the API server pod specification file /etc/kubernetes/manifests/kube-apiserver.yaml
on the control plane node and set the below parameter.
--anonymous-auth=false

1.2.3 Edit the API server pod specification file /etc/kubernetes/manifests/kube-apiserver.yaml
on the control plane node and add the `DenyServiceExternalIPs` plugin
to the enabled admission plugins, as such --enable-admission-plugin=DenyServiceExternalIPs.

1.2.16 Edit the API server pod specification file /etc/kubernetes/manifests/kube-apiserver.yaml
on the control plane node and set the --audit-log-path parameter to a suitable path and
file where you would like audit logs to be written, for example,
--audit-log-path=/var/log/apiserver/audit.log

1.2.17 Edit the API server pod specification file /etc/kubernetes/manifests/kube-apiserver.yaml
on the control plane node and set the --audit-log-maxage parameter to 30
or as an appropriate number of days, for example,
--audit-log-maxage=30

1.2.18 Edit the API server pod specification file /etc/kubernetes/manifests/kube-apiserver.yaml
on the control plane node and set the --audit-log-maxbackup parameter to 10 or to an appropriate
value. For example,
--audit-log-maxbackup=10

1.2.19 Edit the API server pod specification file /etc/kubernetes/manifests/kube-apiserver.yaml
on the control plane node and set the --audit-log-maxsize parameter to an appropriate size in MB.
For example, to set it as 100 MB, --audit-log-maxsize=100

1.2.20 Edit the API server pod specification file /etc/kubernetes/manifests/kube-apiserver.yaml
and set the below parameter as appropriate and if needed.
For example, --request-timeout=300s

1.2.30 Edit the API server pod specification file /etc/kubernetes/manifests/kube-apiserver.yaml on the Control Plane node and set the --service-account-extend-token-expiration parameter to false.
`--service-account-extend-token-expiration=false`
By default, this parameter is set to true.

1.3.7 Edit the Controller Manager pod specification file /etc/kubernetes/manifests/kube-controller-manager.yaml
on the control plane node and ensure the correct value for the --bind-address parameter

1.4.2 Edit the Scheduler pod specification file /etc/kubernetes/manifests/kube-scheduler.yaml
on the control plane node and ensure the correct value for the --bind-address parameter


== Summary master ==
46 checks PASS
9 checks FAIL
5 checks WARN
0 checks INFO

[INFO] 2 Etcd Node Configuration
[INFO] 2 Etcd Node Configuration
[PASS] 2.1 Ensure that the --cert-file and --key-file arguments are set as appropriate (Automated)
[PASS] 2.2 Ensure that the --client-cert-auth argument is set to true (Automated)
[PASS] 2.3 Ensure that the --auto-tls argument is not set to true (Automated)
[PASS] 2.4 Ensure that the --peer-cert-file and --peer-key-file arguments are set as appropriate (Automated)
[PASS] 2.5 Ensure that the --peer-client-cert-auth argument is set to true (Automated)
[PASS] 2.6 Ensure that the --peer-auto-tls argument is not set to true (Automated)
[PASS] 2.7 Ensure that a unique Certificate Authority is used for etcd (Manual)

== Summary etcd ==
7 checks PASS
0 checks FAIL
0 checks WARN
0 checks INFO

[INFO] 3 Control Plane Configuration
[INFO] 3.1 Authentication and Authorization
[WARN] 3.1.1 Client certificate authentication should not be used for users (Manual)
[WARN] 3.1.2 Service account token authentication should not be used for users (Manual)
[WARN] 3.1.3 Bootstrap token authentication should not be used for users (Manual)
[INFO] 3.2 Logging
[WARN] 3.2.1 Ensure that a minimal audit policy is created (Manual)
[WARN] 3.2.2 Ensure that the audit policy covers key security concerns (Manual)

== Remediations controlplane ==
3.1.1 Alternative mechanisms provided by Kubernetes such as the use of OIDC should be
implemented in place of client certificates.

3.1.2 Alternative mechanisms provided by Kubernetes such as the use of OIDC should be implemented
in place of service account tokens.

3.1.3 Alternative mechanisms provided by Kubernetes such as the use of OIDC should be implemented
in place of bootstrap tokens.

3.2.1 Create an audit policy file for your cluster.

3.2.2 Review the audit policy provided for the cluster and ensure that it covers
at least the following areas,
- Access to Secrets managed by the cluster. Care should be taken to only
  log Metadata for requests to Secrets, ConfigMaps, and TokenReviews, in
  order to avoid risk of logging sensitive data.
- Modification of Pod and Deployment objects.
- Use of `pods/exec`, `pods/portforward`, `pods/proxy` and `services/proxy`.
For most requests, minimally logging at the Metadata level is recommended
(the most basic level of logging).


== Summary controlplane ==
0 checks PASS
0 checks FAIL
5 checks WARN
0 checks INFO

[INFO] 5 Kubernetes Policies
[INFO] 5.1 RBAC and Service Accounts
[WARN] 5.1.1 Ensure that the cluster-admin role is only used where required (Manual)
[WARN] 5.1.2 Minimize access to secrets (Manual)
[WARN] 5.1.3 Minimize wildcard use in Roles and ClusterRoles (Manual)
[WARN] 5.1.4 Minimize access to create pods (Manual)
[WARN] 5.1.5 Ensure that default service accounts are not actively used (Manual)
[WARN] 5.1.6 Ensure that Service Account Tokens are only mounted where necessary (Manual)
[WARN] 5.1.7 Avoid use of system:masters group (Manual)
[WARN] 5.1.8 Limit use of the Bind, Impersonate and Escalate permissions in the Kubernetes cluster (Manual)
[WARN] 5.1.9 Minimize access to create persistent volumes (Manual)
[WARN] 5.1.10 Minimize access to the proxy sub-resource of nodes (Manual)
[WARN] 5.1.11 Minimize access to the approval sub-resource of certificatesigningrequests objects (Manual)
[WARN] 5.1.12 Minimize access to webhook configuration objects (Manual)
[WARN] 5.1.13 Minimize access to the service account token creation (Manual)
[INFO] 5.2 Pod Security Standards
[WARN] 5.2.1 Ensure that the cluster has at least one active policy control mechanism in place (Manual)
[WARN] 5.2.2 Minimize the admission of privileged containers (Manual)
[WARN] 5.2.3 Minimize the admission of containers wishing to share the host process ID namespace (Manual)
[WARN] 5.2.4 Minimize the admission of containers wishing to share the host IPC namespace (Manual)
[WARN] 5.2.5 Minimize the admission of containers wishing to share the host network namespace (Manual)
[WARN] 5.2.6 Minimize the admission of containers with allowPrivilegeEscalation (Manual)
[WARN] 5.2.7 Minimize the admission of root containers (Manual)
[WARN] 5.2.8 Minimize the admission of containers with the NET_RAW capability (Manual)
[WARN] 5.2.9 Minimize the admission of containers with capabilities assigned (Manual)
[WARN] 5.2.10 Minimize the admission of Windows HostProcess containers (Manual)
[WARN] 5.2.11 Minimize the admission of HostPath volumes (Manual)
[WARN] 5.2.12 Minimize the admission of containers which use HostPorts (Manual)
[INFO] 5.3 Network Policies and CNI
[WARN] 5.3.1 Ensure that the CNI in use supports NetworkPolicies (Manual)
[WARN] 5.3.2 Ensure that all Namespaces have NetworkPolicies defined (Manual)
[INFO] 5.4 Secrets Management
[WARN] 5.4.1 Prefer using Secrets as files over Secrets as environment variables (Manual)
[WARN] 5.4.2 Consider external secret storage (Manual)
[INFO] 5.5 Extensible Admission Control
[WARN] 5.5.1 Configure Image Provenance using ImagePolicyWebhook admission controller (Manual)
[INFO] 5.6 General Policies
[WARN] 5.6.1 Create administrative boundaries between resources using namespaces (Manual)
[WARN] 5.6.2 Ensure that the seccomp profile is set to docker/default in your Pod definitions (Manual)
[WARN] 5.6.3 Apply SecurityContext to your Pods and Containers (Manual)
[WARN] 5.6.4 The default namespace should not be used (Manual)

== Remediations policies ==
5.1.1 Identify all clusterrolebindings to the cluster-admin role. Check if they are used and
if they need this role or if they could use a role with fewer privileges.
Where possible, first bind users to a lower privileged role and then remove the
clusterrolebinding to the cluster-admin role : kubectl delete clusterrolebinding [name]
Condition: is_compliant is false if rolename is not cluster-admin and rolebinding is cluster-admin.

5.1.2 Where possible, remove get, list and watch access to Secret objects in the cluster.

5.1.3 Where possible replace any use of wildcards ["*"] in roles and clusterroles with specific
objects or actions.
Condition: role_is_compliant is false if ["*"] is found in rules.
Condition: clusterrole_is_compliant is false if ["*"] is found in rules.

5.1.4 Where possible, remove create access to pod objects in the cluster.

5.1.5 Create explicit service accounts wherever a Kubernetes workload requires specific access
to the Kubernetes API server.
Modify the configuration of each default service account to include this value
`automountServiceAccountToken: false`.

5.1.6 Modify the definition of ServiceAccounts and Pods which do not need to mount service
account tokens to disable it, with `automountServiceAccountToken: false`.
If both the ServiceAccount and the Pod's .spec specify a value for automountServiceAccountToken, the Pod spec takes precedence.
Condition: Pod is_compliant to true when
  - ServiceAccount is automountServiceAccountToken: false and Pod is automountServiceAccountToken: false or notset
  - ServiceAccount is automountServiceAccountToken: true notset and Pod is automountServiceAccountToken: false

5.1.7 Remove the system:masters group from all users in the cluster.

5.1.8 Where possible, remove the impersonate, bind and escalate rights from subjects.

5.1.9 Where possible, remove create access to PersistentVolume objects in the cluster.

5.1.10 Where possible, remove access to the proxy sub-resource of node objects.

5.1.11 Where possible, remove access to the approval sub-resource of certificatesigningrequests objects.

5.1.12 Where possible, remove access to the validatingwebhookconfigurations or mutatingwebhookconfigurations objects

5.1.13 Where possible, remove access to the token sub-resource of serviceaccount objects.

5.2.1 Ensure that either Pod Security Admission or an external policy control system is in place
for every namespace which contains user workloads.

5.2.2 Add policies to each namespace in the cluster which has user workloads to restrict the
admission of privileged containers.
Audit: the audit list all pods' containers to retrieve their .securityContext.privileged value.
Condition: is_compliant is false if container's `.securityContext.privileged` is set to `true`.
Default: by default, there are no restrictions on the creation of privileged containers.

5.2.3 Add policies to each namespace in the cluster which has user workloads to restrict the
admission of `hostPID` containers.
Audit: the audit retrieves each Pod' spec.hostPID.
Condition: is_compliant is false if Pod's spec.hostPID is set to `true`.
Default: by default, there are no restrictions on the creation of hostPID containers.

5.2.4 Add policies to each namespace in the cluster which has user workloads to restrict the
admission of `hostIPC` containers.
Audit: the audit retrieves each Pod' spec.IPC.
Condition: is_compliant is false if Pod's spec.hostIPC is set to `true`.
Default: by default, there are no restrictions on the creation of hostIPC containers.

5.2.5 Add policies to each namespace in the cluster which has user workloads to restrict the
admission of `hostNetwork` containers.
Audit: the audit retrieves each Pod' spec.hostNetwork.
Condition: is_compliant is false if Pod's spec.hostNetwork is set to `true`.
Default: by default, there are no restrictions on the creation of hostNetwork containers.

5.2.6 Add policies to each namespace in the cluster which has user workloads to restrict the
admission of containers with `.securityContext.allowPrivilegeEscalation` set to `true`.
Audit: the audit retrieves each Pod's container(s) `.securityContext.allowPrivilegeEscalation`.
Condition: is_compliant is false if container's `.securityContext.allowPrivilegeEscalation` is set to `true`.
Default: If notset, privilege escalation is allowed (default to true). However if PSP/PSA is used with a `restricted` profile,
privilege escalation is explicitly disallowed unless configured otherwise.

5.2.7 Create a policy for each namespace in the cluster, ensuring that either `MustRunAsNonRoot`
or `MustRunAs` with the range of UIDs not including 0, is set.

5.2.8 Add policies to each namespace in the cluster which has user workloads to restrict the
admission of containers with the `NET_RAW` capability.

5.2.9 Review the use of capabilities in applications running on your cluster. Where a
namespace contains applications which do not require any Linux capabilities to operate
consider adding a policy which forbids the admission of containers which do not drop all
capabilities.

5.2.10 Add policies to each namespace in the cluster which has user workloads to restrict the
admission of containers that have `.securityContext.windowsOptions.hostProcess` set to `true`.

5.2.11 Add policies to each namespace in the cluster which has user workloads to restrict the
admission of containers with `hostPath` volumes.

5.2.12 Add policies to each namespace in the cluster which has user workloads to restrict the
admission of containers which use `hostPort` sections.

5.3.1 If the CNI plugin in use does not support network policies, consideration should be given to
making use of a different plugin, or finding an alternate mechanism for restricting traffic
in the Kubernetes cluster.

5.3.2 Follow the documentation and create NetworkPolicy objects as you need them.

5.4.1 If possible, rewrite application code to read Secrets from mounted secret files, rather than
from environment variables.

5.4.2 Refer to the Secrets management options offered by your cloud provider or a third-party
secrets management solution.

5.5.1 Follow the Kubernetes documentation and setup image provenance.

5.6.1 Follow the documentation and create namespaces for objects in your deployment as you need
them.

5.6.2 Use `securityContext` to enable the docker/default seccomp profile in your pod definitions.
An example is as below:
  securityContext:
    seccompProfile:
      type: RuntimeDefault

5.6.3 Follow the Kubernetes documentation and apply SecurityContexts to your Pods. For a
suggested list of SecurityContexts, you may refer to the CIS Security Benchmark for Docker
Containers.

5.6.4 Ensure that namespaces are created to allow for appropriate segregation of Kubernetes
resources and that all new resources are created in a specific namespace.


== Summary policies ==
0 checks PASS
0 checks FAIL
34 checks WARN
0 checks INFO

== Summary total ==
53 checks PASS
9 checks FAIL
44 checks WARN
0 checks INFO

```

## Appendix B — node job raw output (deimos.lan, targets: node,policies)

```text
[INFO] 4 Worker Node Security Configuration
[INFO] 4.1 Worker Node Configuration Files
[PASS] 4.1.1 Ensure that the kubelet service file permissions are set to 600 or more restrictive (Automated)
[PASS] 4.1.2 Ensure that the kubelet service file ownership is set to root:root (Automated)
[WARN] 4.1.3 If proxy kubeconfig file exists ensure permissions are set to 600 or more restrictive (Manual)
[WARN] 4.1.4 If proxy kubeconfig file exists ensure ownership is set to root:root (Manual)
[PASS] 4.1.5 Ensure that the --kubeconfig kubelet.conf file permissions are set to 600 or more restrictive (Automated)
[PASS] 4.1.6 Ensure that the --kubeconfig kubelet.conf file ownership is set to root:root (Automated)
[PASS] 4.1.7 Ensure that the certificate authorities file permissions are set to 644 or more restrictive (Manual)
[PASS] 4.1.8 Ensure that the client certificate authorities file ownership is set to root:root (Manual)
[PASS] 4.1.9 If the kubelet config.yaml configuration file is being used validate permissions set to 600 or more restrictive (Automated)
[PASS] 4.1.10 If the kubelet config.yaml configuration file is being used validate file ownership is set to root:root (Automated)
[INFO] 4.2 Kubelet
[PASS] 4.2.1 Ensure that the --anonymous-auth argument is set to false (Automated)
[PASS] 4.2.2 Ensure that the --authorization-mode argument is not set to AlwaysAllow (Automated)
[PASS] 4.2.3 Ensure that the --client-ca-file argument is set as appropriate (Automated)
[PASS] 4.2.4 Verify that if defined, the --read-only-port argument is set to 0 (Manual)
[PASS] 4.2.5 Ensure that the --streaming-connection-idle-timeout argument is not set to 0 (Manual)
[PASS] 4.2.6 Ensure that the --make-iptables-util-chains argument is set to true (Automated)
[WARN] 4.2.7 Ensure that the --hostname-override argument is not set (Manual)
[PASS] 4.2.8 Ensure that the eventRecordQPS argument is set to a level which ensures appropriate event capture (Manual)
[WARN] 4.2.9 Ensure that the --tls-cert-file and --tls-private-key-file arguments are set as appropriate (Manual)
[PASS] 4.2.10 Ensure that the --rotate-certificates argument is not set to false (Automated)
[PASS] 4.2.11 Verify that the RotateKubeletServerCertificate argument is set to true (Manual)
[WARN] 4.2.12 Ensure that the Kubelet only makes use of Strong Cryptographic Ciphers (Manual)
[PASS] 4.2.13 Ensure that a limit is set on pod PIDs (Manual)
[PASS] 4.2.14 Ensure that the --seccomp-default parameter is set to true (Manual)
[INFO] 4.3 kube-proxy
[FAIL] 4.3.1 Ensure that the kube-proxy metrics service is bound to localhost (Automated)

== Remediations node ==
4.1.3 Run the below command (based on the file location on your system) on the each worker node.
For example,
chmod 600 /etc/kubernetes/proxy.conf

4.1.4 Run the below command (based on the file location on your system) on the each worker node.
For example, chown root:root /etc/kubernetes/proxy.conf

4.2.7 Edit the kubelet service file /etc/systemd/system/kubelet.service
on each worker node and remove the --hostname-override argument from the
KUBELET_SYSTEM_PODS_ARGS variable.
Based on your system, restart the kubelet service. For example,
systemctl daemon-reload
systemctl restart kubelet.service

4.2.9 If using a Kubelet config file, edit the file to set `tlsCertFile` to the location
of the certificate file to use to identify this Kubelet, and `tlsPrivateKeyFile`
to the location of the corresponding private key file.
If using command line arguments, edit the kubelet service file
/etc/systemd/system/kubelet.service on each worker node and
set the below parameters in KUBELET_CERTIFICATE_ARGS variable.
--tls-cert-file=<path/to/tls-certificate-file>
--tls-private-key-file=<path/to/tls-key-file>
Based on your system, restart the kubelet service. For example,
systemctl daemon-reload
systemctl restart kubelet.service

4.2.12 If using a Kubelet config file, edit the file to set `tlsCipherSuites` to
TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305,TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384
or to a subset of these values.
If using executable arguments, edit the kubelet service file
/etc/systemd/system/kubelet.service on each worker node and
set the --tls-cipher-suites parameter as follows, or to a subset of these values.
--tls-cipher-suites=TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305,TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384
Based on your system, restart the kubelet service. For example:
systemctl daemon-reload
systemctl restart kubelet.service

4.3.1 Modify or remove any values which bind the metrics service to a non-localhost address.
The default value is 127.0.0.1:10249.


== Summary node ==
19 checks PASS
1 checks FAIL
5 checks WARN
0 checks INFO

[INFO] 5 Kubernetes Policies
[INFO] 5.1 RBAC and Service Accounts
[WARN] 5.1.1 Ensure that the cluster-admin role is only used where required (Manual)
[WARN] 5.1.2 Minimize access to secrets (Manual)
[WARN] 5.1.3 Minimize wildcard use in Roles and ClusterRoles (Manual)
[WARN] 5.1.4 Minimize access to create pods (Manual)
[WARN] 5.1.5 Ensure that default service accounts are not actively used (Manual)
[WARN] 5.1.6 Ensure that Service Account Tokens are only mounted where necessary (Manual)
[WARN] 5.1.7 Avoid use of system:masters group (Manual)
[WARN] 5.1.8 Limit use of the Bind, Impersonate and Escalate permissions in the Kubernetes cluster (Manual)
[WARN] 5.1.9 Minimize access to create persistent volumes (Manual)
[WARN] 5.1.10 Minimize access to the proxy sub-resource of nodes (Manual)
[WARN] 5.1.11 Minimize access to the approval sub-resource of certificatesigningrequests objects (Manual)
[WARN] 5.1.12 Minimize access to webhook configuration objects (Manual)
[WARN] 5.1.13 Minimize access to the service account token creation (Manual)
[INFO] 5.2 Pod Security Standards
[WARN] 5.2.1 Ensure that the cluster has at least one active policy control mechanism in place (Manual)
[WARN] 5.2.2 Minimize the admission of privileged containers (Manual)
[WARN] 5.2.3 Minimize the admission of containers wishing to share the host process ID namespace (Manual)
[WARN] 5.2.4 Minimize the admission of containers wishing to share the host IPC namespace (Manual)
[WARN] 5.2.5 Minimize the admission of containers wishing to share the host network namespace (Manual)
[WARN] 5.2.6 Minimize the admission of containers with allowPrivilegeEscalation (Manual)
[WARN] 5.2.7 Minimize the admission of root containers (Manual)
[WARN] 5.2.8 Minimize the admission of containers with the NET_RAW capability (Manual)
[WARN] 5.2.9 Minimize the admission of containers with capabilities assigned (Manual)
[WARN] 5.2.10 Minimize the admission of Windows HostProcess containers (Manual)
[WARN] 5.2.11 Minimize the admission of HostPath volumes (Manual)
[WARN] 5.2.12 Minimize the admission of containers which use HostPorts (Manual)
[INFO] 5.3 Network Policies and CNI
[WARN] 5.3.1 Ensure that the CNI in use supports NetworkPolicies (Manual)
[WARN] 5.3.2 Ensure that all Namespaces have NetworkPolicies defined (Manual)
[INFO] 5.4 Secrets Management
[WARN] 5.4.1 Prefer using Secrets as files over Secrets as environment variables (Manual)
[WARN] 5.4.2 Consider external secret storage (Manual)
[INFO] 5.5 Extensible Admission Control
[WARN] 5.5.1 Configure Image Provenance using ImagePolicyWebhook admission controller (Manual)
[INFO] 5.6 General Policies
[WARN] 5.6.1 Create administrative boundaries between resources using namespaces (Manual)
[WARN] 5.6.2 Ensure that the seccomp profile is set to docker/default in your Pod definitions (Manual)
[WARN] 5.6.3 Apply SecurityContext to your Pods and Containers (Manual)
[WARN] 5.6.4 The default namespace should not be used (Manual)

== Remediations policies ==
5.1.1 Identify all clusterrolebindings to the cluster-admin role. Check if they are used and
if they need this role or if they could use a role with fewer privileges.
Where possible, first bind users to a lower privileged role and then remove the
clusterrolebinding to the cluster-admin role : kubectl delete clusterrolebinding [name]
Condition: is_compliant is false if rolename is not cluster-admin and rolebinding is cluster-admin.

5.1.2 Where possible, remove get, list and watch access to Secret objects in the cluster.

5.1.3 Where possible replace any use of wildcards ["*"] in roles and clusterroles with specific
objects or actions.
Condition: role_is_compliant is false if ["*"] is found in rules.
Condition: clusterrole_is_compliant is false if ["*"] is found in rules.

5.1.4 Where possible, remove create access to pod objects in the cluster.

5.1.5 Create explicit service accounts wherever a Kubernetes workload requires specific access
to the Kubernetes API server.
Modify the configuration of each default service account to include this value
`automountServiceAccountToken: false`.

5.1.6 Modify the definition of ServiceAccounts and Pods which do not need to mount service
account tokens to disable it, with `automountServiceAccountToken: false`.
If both the ServiceAccount and the Pod's .spec specify a value for automountServiceAccountToken, the Pod spec takes precedence.
Condition: Pod is_compliant to true when
  - ServiceAccount is automountServiceAccountToken: false and Pod is automountServiceAccountToken: false or notset
  - ServiceAccount is automountServiceAccountToken: true notset and Pod is automountServiceAccountToken: false

5.1.7 Remove the system:masters group from all users in the cluster.

5.1.8 Where possible, remove the impersonate, bind and escalate rights from subjects.

5.1.9 Where possible, remove create access to PersistentVolume objects in the cluster.

5.1.10 Where possible, remove access to the proxy sub-resource of node objects.

5.1.11 Where possible, remove access to the approval sub-resource of certificatesigningrequests objects.

5.1.12 Where possible, remove access to the validatingwebhookconfigurations or mutatingwebhookconfigurations objects

5.1.13 Where possible, remove access to the token sub-resource of serviceaccount objects.

5.2.1 Ensure that either Pod Security Admission or an external policy control system is in place
for every namespace which contains user workloads.

5.2.2 Add policies to each namespace in the cluster which has user workloads to restrict the
admission of privileged containers.
Audit: the audit list all pods' containers to retrieve their .securityContext.privileged value.
Condition: is_compliant is false if container's `.securityContext.privileged` is set to `true`.
Default: by default, there are no restrictions on the creation of privileged containers.

5.2.3 Add policies to each namespace in the cluster which has user workloads to restrict the
admission of `hostPID` containers.
Audit: the audit retrieves each Pod' spec.hostPID.
Condition: is_compliant is false if Pod's spec.hostPID is set to `true`.
Default: by default, there are no restrictions on the creation of hostPID containers.

5.2.4 Add policies to each namespace in the cluster which has user workloads to restrict the
admission of `hostIPC` containers.
Audit: the audit retrieves each Pod' spec.IPC.
Condition: is_compliant is false if Pod's spec.hostIPC is set to `true`.
Default: by default, there are no restrictions on the creation of hostIPC containers.

5.2.5 Add policies to each namespace in the cluster which has user workloads to restrict the
admission of `hostNetwork` containers.
Audit: the audit retrieves each Pod' spec.hostNetwork.
Condition: is_compliant is false if Pod's spec.hostNetwork is set to `true`.
Default: by default, there are no restrictions on the creation of hostNetwork containers.

5.2.6 Add policies to each namespace in the cluster which has user workloads to restrict the
admission of containers with `.securityContext.allowPrivilegeEscalation` set to `true`.
Audit: the audit retrieves each Pod's container(s) `.securityContext.allowPrivilegeEscalation`.
Condition: is_compliant is false if container's `.securityContext.allowPrivilegeEscalation` is set to `true`.
Default: If notset, privilege escalation is allowed (default to true). However if PSP/PSA is used with a `restricted` profile,
privilege escalation is explicitly disallowed unless configured otherwise.

5.2.7 Create a policy for each namespace in the cluster, ensuring that either `MustRunAsNonRoot`
or `MustRunAs` with the range of UIDs not including 0, is set.

5.2.8 Add policies to each namespace in the cluster which has user workloads to restrict the
admission of containers with the `NET_RAW` capability.

5.2.9 Review the use of capabilities in applications running on your cluster. Where a
namespace contains applications which do not require any Linux capabilities to operate
consider adding a policy which forbids the admission of containers which do not drop all
capabilities.

5.2.10 Add policies to each namespace in the cluster which has user workloads to restrict the
admission of containers that have `.securityContext.windowsOptions.hostProcess` set to `true`.

5.2.11 Add policies to each namespace in the cluster which has user workloads to restrict the
admission of containers with `hostPath` volumes.

5.2.12 Add policies to each namespace in the cluster which has user workloads to restrict the
admission of containers which use `hostPort` sections.

5.3.1 If the CNI plugin in use does not support network policies, consideration should be given to
making use of a different plugin, or finding an alternate mechanism for restricting traffic
in the Kubernetes cluster.

5.3.2 Follow the documentation and create NetworkPolicy objects as you need them.

5.4.1 If possible, rewrite application code to read Secrets from mounted secret files, rather than
from environment variables.

5.4.2 Refer to the Secrets management options offered by your cloud provider or a third-party
secrets management solution.

5.5.1 Follow the Kubernetes documentation and setup image provenance.

5.6.1 Follow the documentation and create namespaces for objects in your deployment as you need
them.

5.6.2 Use `securityContext` to enable the docker/default seccomp profile in your pod definitions.
An example is as below:
  securityContext:
    seccompProfile:
      type: RuntimeDefault

5.6.3 Follow the Kubernetes documentation and apply SecurityContexts to your Pods. For a
suggested list of SecurityContexts, you may refer to the CIS Security Benchmark for Docker
Containers.

5.6.4 Ensure that namespaces are created to allow for appropriate segregation of Kubernetes
resources and that all new resources are created in a specific namespace.


== Summary policies ==
0 checks PASS
0 checks FAIL
34 checks WARN
0 checks INFO

== Summary total ==
19 checks PASS
1 checks FAIL
39 checks WARN
0 checks INFO

```
