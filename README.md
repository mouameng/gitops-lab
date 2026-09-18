# GitOps Lab

Objectif :

- Préparer le CKA
- Apprendre Kubernetes
- Apprendre GitOps avec ArgoCD
- Pouvoir reconstruire entièrement le cluster à tout moment

Architecture :

Git
  ↓
ArgoCD
  ↓
Kind
  ↓
Applications

Règles :

- Tout ce qui est dans Kubernetes doit être versionné dans Git.
- Les modifications manuelles sont uniquement autorisées à des fins d'apprentissage.
- Le cluster doit pouvoir être détruit et recréé à partir du dépôt Git.

