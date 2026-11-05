# argocd/

What the root Application (`bootstrap/root.yaml`) syncs: only Argo CD objects (Applications, AppProjects, ApplicationSets). Each of those points at the real manifests elsewhere in the repo.

Argo reads only the `.yaml`, `.yml` and `.json` files here, so this README is ignored.
