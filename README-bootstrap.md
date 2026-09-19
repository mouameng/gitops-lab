# Bootstrap GitOps autonome ArgoCD / Kind

## Hypotheses retenues

- Depot public : `https://github.com/mouameng/gitops-lab.git`
- Branche : `main`
- Contextes kubectl : `kind-gitops-management` et `kind-gitops-lab`
- Nom ArgoCD du workload : `workload-dev`
- Les deux clusters Kind partagent le reseau Docker `kind`
- API workload joignable depuis le management via `https://gitops-lab-control-plane:6443`

## Limite structurelle importante

Un cluster ArgoCD neuf ne peut pas inventer seul les identifiants du cluster workload. Le premier enrôlement exige donc une racine de confiance. Ici, elle est matérialisée par un `SealedSecret` commité et par la cle privee Sealed Secrets sauvegardee hors Git. Apres cette initialisation unique, les PRA du cluster management sont automatisables par `bootstrap-management.sh`.

Ne commite jamais : token brut, Secret ArgoCD en clair ou cle privee Sealed Secrets.

## Installation dans le depot

Copier le contenu de cette archive a la racine du depot. Les fichiers existants portant le meme nom doivent etre compares avant remplacement.

Le Root App surveille maintenant tout `argocd/` avec `directory.recurse: true`. Les AppProjects ont la vague `-50`, Sealed Secrets la vague `-40`, puis l’enregistrement du cluster la vague `-20`. Les Applications métier existantes restent à la vague `0`. Les Applications existantes doivent idealement porter une vague `0`.

## Premier enrôlement

1. Installer ArgoCD et appliquer le Root App :

```bash
./scripts/bootstrap-management.sh
```

2. Attendre que `sealed-secrets` soit Healthy, puis generer le manifeste chiffre :

```bash
./scripts/generate-workload-registration.sh
git add argocd/cluster-registration/workload-dev-sealedsecret.yaml
git commit -m "feat(argocd): register workload-dev via SealedSecret"
git push
```

3. Sauvegarder la cle de recuperation hors Git :

```bash
./scripts/backup-sealed-secrets-key.sh
```

## PRA management suivant

```bash
kind create cluster --name gitops-management --config clusters/management/kind-config.yaml
SEALED_KEYS="$HOME/.config/gitops-lab/sealed-secrets-key.yaml" ./scripts/bootstrap-management.sh
```

Le Root App recrée ensuite les projets, l'enregistrement du workload et les Applications.

## Verification factuelle

```bash
kubectl --context kind-gitops-management get applications -n argocd
kubectl --context kind-gitops-management get appprojects -n argocd
kubectl --context kind-gitops-management get secret workload-dev -n argocd \
  -o jsonpath='{.metadata.labels.argocd\.argoproj\.io/secret-type}{"\n"}'
kubectl --context kind-gitops-management get secret -n sealed-secrets \
  -l sealedsecrets.bitnami.com/sealed-secrets-key=active
```

## Points a adapter

- Verifier la version ArgoCD fixee dans `bootstrap-management.sh` avant emploi.
- Verifier la version Helm de Sealed Secrets.
- Si le nom du conteneur Kind workload differe, adapter `SERVER`.
- Pour davantage de moindre privilege, remplacer `cluster-admin` par des roles limites aux namespaces et ressources geres.
