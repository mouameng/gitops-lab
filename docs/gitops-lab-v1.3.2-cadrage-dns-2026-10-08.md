# GitOps Lab — Cadrage v1.3.2 : DNS Kubernetes du lab (document de reprise)

**Statut : cadrage, aucune modification du lab n'a été faite pour ce chantier.** Ce document sert de base de reprise après la clôture de la v1.3.1 (dépôt de secours GitHub, tag `v1.3.1`). Il regroupe les tests de faisabilité de la CI menés le 8 octobre 2026, le diagnostic DNS qui en est sorti, la décision d'architecture et les points encore à trancher.

**Convention de lecture :**
- **confirmé** : sortie de commande rapportée dans les échanges ;
- **déduit** : conséquence logique d'éléments confirmés, non testée directement ;
- **hypothèse** : explication plausible, non prouvée ;
- **à valider** : pas encore testé.

---

## 1. Où l'on en est

- v1.3.0 : Gitea source de vérité, installation directe au PRA.
- v1.3.1 (clôturée, tag `v1.3.1`) : push mirror Gitea → GitHub, `scripts/check-github-mirror.sh`, profils `lab` / `exploit` dans le bootstrap, deux PRA rejoués.
- Le document `docs/gitops-lab-v1.3.1-cloturee-2026-10-08.md` indique encore « CI Gitea Actions = v1.3.2 ». **Cette feuille de route est révisée ici** : voir section 7.

**Chantier CI (mis en pause) :** le test de faisabilité DinD est réussi (section 2), mais il a révélé un problème de nommage DNS qui doit être réglé avant d'installer le runner.

---

## 2. Tests de faisabilité CI réalisés le 8 octobre 2026

### 2.1 Relevé de l'environnement (confirmé)

| Élément | Constat |
|---|---|
| Configuration Actions de Gitea | Section `[actions]` absente de `app.ini` : valeurs par défaut |
| Nombre de runners enregistrés | **Non relevé** (Administration du site → Actions → Runners) |
| Docker de la machine | 4 CPU, ~11,7 GiB de RAM, cgroups v2, pilote `systemd`, stockage `overlayfs` |
| Consommation des 3 nœuds Kind | ~1,2 GiB (prod), ~1,1 GiB (dev), ~2,6 GiB (management) |
| Réservations du nœud management | CPU 1150m (28 %), mémoire 618 Mi (5 %) |

### 2.2 Test DinD dans un pod jetable (confirmé)

Manifeste local : `~/lab/tools/ci/dind-test.yaml` (namespace `ci-dind-test`, pod `dind-test`, image `docker:dind`, privilégié, 1 CPU et 2 GiB maximum, `emptyDir` sur `/var/lib/docker`).

| Contrôle | Résultat |
|---|---|
| Démarrage du démon | `dockerd` répond en 10 s (Docker 29.8.2) |
| Pilote de stockage du Docker interne | `overlayfs`, cgroups v2 : pas de repli sur `vfs` |
| `docker run alpine` | Image téléchargée depuis Docker Hub, conteneur exécuté |
| `docker build` d'une image minimale | Image construite et exécutée (`build-ok`) |

**Limites :** une image `alpine` est petite. Un éventuel problème de MTU sur le réseau imbriqué n'apparaîtrait qu'avec de plus grosses images : à surveiller au build réel de 2048.

### 2.3 Réseau vu depuis un conteneur imbriqué (confirmé)

- Le conteneur imbriqué **hérite du DNS du cluster** (`10.96.0.10`) avec les mêmes domaines de recherche.
- L'URL interne de Gitea répond : `http://gitea-http.gitea.svc.cluster.local:3000/api/healthz` renvoie `"status": "pass"` (base de données et cache).
- **`gitea.local` résout vers `127.0.0.1`** depuis un conteneur imbriqué. Pour un job, c'est une adresse inutilisable : elle désigne le conteneur lui-même.

### 2.4 Ce qui n'a PAS été testé

- **Accès TLS au registre depuis un conteneur imbriqué** (étape prévue mais **pas exécutée**) : joignabilité de `172.18.0.2:443` depuis le nœud management, validation du certificat par la CA du lab, réponse de `/v2/`.
- **Push d'une image** vers le registre OCI de Gitea, avec un jeton dédié.
- **Enregistrement d'un runner** auprès de Gitea.
- **Build d'une image réelle (2048)** et comportement réseau avec de grosses couches.
- **Consommation de la limite inotify** (512) par le démon imbriqué.

---

## 3. Diagnostic DNS : `gitea.local → 127.0.0.1`

### 3.1 Chaîne de résolution

```text
Conteneur de job
  -> CoreDNS du cluster management (10.96.0.10)
  -> résolveur du nœud Kind : DNS intégré de Docker (172.18.0.1)
  -> résolveur de WSL (10.255.255.254)
  -> Windows : fichier hosts
```

| Maillon | Statut | Preuve |
|---|---|---|
| Le conteneur imbriqué utilise `10.96.0.10` | confirmé | `resolv.conf` du conteneur |
| Aucune entrée `gitea.local` dans les `/etc/hosts` du pod ni du conteneur imbriqué | confirmé | `cat /etc/hosts` des deux |
| Le DNS du cluster répond lui-même `127.0.0.1` | confirmé | `nslookup gitea.local 10.96.0.10` |
| CoreDNS n'a aucune entrée `gitea.local` ; il transmet à `/etc/resolv.conf` du nœud (`forward . /etc/resolv.conf`) | confirmé | Corefile |
| Le nœud Kind utilise `172.18.0.1` (DNS Docker) et signale `ExtServers: [host(10.255.255.254)]` | confirmé | `resolv.conf` du nœud |
| Le `/etc/hosts` de WSL ne contient rien sur `gitea` | confirmé | `grep` |
| **Le hosts Windows contient `127.0.0.1 gitea.local` (ligne 24)** | confirmé | `grep` sur `/mnt/c/Windows/System32/drivers/etc/hosts` |
| WSL relaie les entrées du hosts Windows aux résolutions DNS | **déduit** | WSL génère son `resolv.conf` automatiquement, aucun réglage DNS explicite ; non testé directement |

### 3.2 Pourquoi c'est un problème

La même entrée est correcte pour ton navigateur (le port est publié sur ta machine) et fausse pour tout ce qui tourne dans un cluster, où `127.0.0.1` désigne le conteneur lui-même. **`gitea.local` doit donc renvoyer deux adresses selon le demandeur :**

| Demandeur | Adresse attendue | État actuel |
|---|---|---|
| Windows, navigateur, WSL | `127.0.0.1` | OK (hosts Windows) |
| Nœuds workload (containerd) | `172.18.0.2` | OK : entrée posée par `scripts/configure-workload-registry.sh` (confirmé dans les journaux de PRA) |
| Pods, démon DinD, conteneurs de jobs du management | `172.18.0.2` | **KO : renvoie `127.0.0.1`** |

L'adresse `172.18.0.2` est celle du nœud management (confirmée par le bootstrap : « management 172.18.0.2 »). Ce chemin vers le registre depuis le management lui-même reste à tester (2.4).

### 3.3 Conséquences pour la CI

- **Le clonage Git** peut contourner le problème en utilisant l'URL interne du service (qui fonctionne).
- **Le push d'image vers le registre** passe par `gitea.local` : il est bloqué tant que le nom résout vers `127.0.0.1`.
- Une entrée `hostAliases` dans le pod du runner ne corrigerait que **le démon Docker**. Les conteneurs de jobs ont leur propre `/etc/hosts` et interrogent le DNS du cluster : un correctif durable doit donc agir au niveau du DNS du cluster.

---

## 4. Options étudiées

| | Option 1 : `hosts` et entrées par composant | Option 2 : DNS dans Kubernetes | Option 3 : DNS central du lab |
|---|---|---|---|
| **Principe** | Entrées dans les hosts Windows / WSL, `hosts.toml`, `hostAliases`, `--add-host` | CoreDNS du cluster répond pour les noms du lab | Un serveur DNS unique (CoreDNS ou dnsmasq) utilisé par Windows, WSL, Docker, Kind et les pods |
| **Couvre** | Un composant à la fois | Tous les pods du cluster : démon DinD **et** conteneurs de jobs | Tout, navigateur compris |
| **Droits Windows** | Oui, pour le hosts Windows | **Non** | Oui, pour changer le DNS de Windows ou de WSL |
| **Compatibilité PRA** | Bonne, mais dispersée | **Bonne** : déclaratif, reconstruit avec le cluster | Plus complexe : le DNS devient une dépendance de Gitea, du registre et d'Argo CD ; il faut décider comment le retrouver au PRA |
| **Nouveau point de panne** | Non | Non (composant déjà présent) | **Oui** |
| **Effort** | Faible, à répéter | Modéré | Élevé |
| **Intérêt pédagogique** | Faible | Moyen : CoreDNS, résolution Kubernetes, PRA | Fort : zones, split horizon, lien avec la PKI |

**Réutilisation option 2 → option 3 :** si les noms et la zone sont choisis dès maintenant avec soin, l'essentiel du travail (noms, enregistrements, certificats) est réutilisable. Ce qui sera à refaire : la configuration propre à CoreDNS Kubernetes (par exemple l'entrée `hosts` ou `rewrite`), et le traitement des postes clients (Windows, WSL, Docker), qui est le vrai sujet de l'option 3.

---

## 5. Décision retenue

**Option 2 maintenant. Option 3 dans une version ultérieure.**

- Le DNS du lab dans Kubernetes devient la référence pour les pods, le runner et les jobs CI, Argo CD et le registre OCI.
- **Le hosts Windows est conservé** pour l'accès navigateur et WSL.
- **Aucune modification automatique du hosts Windows par le bootstrap** : elle exige des droits administrateur et ajouterait de la complexité à un PRA relancé régulièrement.
- **Le prévol contrôle (sans rien modifier)** que les entrées attendues sont présentes dans le hosts Windows. Résultat informatif (`[OK]` ou `[WARN]`), sans arrêt.
  - Faisabilité : la lecture de `/mnt/c/Windows/System32/drivers/etc/hosts` depuis WSL fonctionne (confirmé le 8 octobre).
  - Le chemin du fichier dépend de l'installation Windows et du montage de `/mnt/c` : le contrôle doit se dégrader proprement en `[WARN]` ou `[INFO]` si le fichier est illisible.

---

## 6. Points à trancher avant d'implémenter

Ces décisions n'ont pas été prises. Elles changent l'ampleur du chantier.

### 6.1 Garder `gitea.local` ou migrer vers `*.lab.local`

Le brouillon de cadrage échangé en conversation citait `gitea.lab.local`, `registry.lab.local` et `argocd.lab.local`. **Ce choix est plus coûteux qu'il n'en a l'air** et ne doit pas être pris à la légère :

| Contrainte | Conséquence d'un changement de nom |
|---|---|
| Certificat `gitea-local` géré par cert-manager | À réémettre avec les nouveaux noms |
| `server.DOMAIN` et `ROOT_URL` de Gitea (`gitea.local`) | À modifier, avec redémarrage |
| URL de dépôt déclarées dans Argo CD (17 références migrées en v1.3.0) | Éventuellement à reprendre, selon l'URL utilisée |
| `hosts.toml` et CA posés sur les nœuds workload par `configure-workload-registry.sh` | À adapter |
| Entrée du hosts Windows | À remplacer ou compléter |

| Variante | Principe | Avantage | Inconvénient |
|---|---|---|---|
| **A. Garder `gitea.local`** | CoreDNS du management répond `gitea.local → 172.18.0.2` (entrée `hosts` ou `rewrite`) | Débloque la CI sans toucher aux certificats, à Gitea ni aux dépôts | Les noms restent en `.local` (suffixe réservé au mDNS, tolérable pour un lab) |
| **B. Passer à `gitea.lab.local`** | Nouveau nom partout | Zone propre, en phase avec l'option 3 | Changement de nom transversal : beaucoup plus de surface de risque |

**Recommandation :** la variante A comme premier livrable. Elle valide le mécanisme avec le moindre risque ; le choix de la zone définitive se fera avec la PKI et le DNS central (v1.4.0), lorsque les noms seront de toute façon revus.

### 6.2 Comment déployer le DNS

- **CoreDNS déjà présent dans `kube-system`** : modification de sa ConfigMap. Aucun nouveau composant, mais la ConfigMap est créée par Kind : un conflit avec Argo CD est possible si on tente de la gérer ainsi. Piste : l'appliquer depuis le bootstrap, avant la Root App, avec dry-run et contrôle, sur le modèle de `configure-workload-registry.sh`.
- **CoreDNS dédié** (déploiement séparé, avec son propre service) : plus pédagogique et géré par GitOps, mais il faut décider qui l'interroge : les pods devraient pointer vers lui (redirection depuis le CoreDNS existant, par une directive `forward` ou `stub`), ce qui reste à concevoir.

**Recommandation provisoire :** commencer par modifier le CoreDNS existant du management (plus simple, et c'est lui que la CI utilisera), puis déplacer ensuite vers un CoreDNS dédié si l'on veut aller plus loin.

### 6.3 Périmètre des clusters

La CI s'exécutera sur le **management**. Les clusters dev et prod ont leur propre CoreDNS. Question à trancher : l'entrée doit-elle y figurer aussi ? Elle n'est utile que si des pods de ces clusters doivent joindre `gitea.local`. Les nœuds workload sont déjà couverts pour containerd.

### 6.4 Numérotation de la version

| Option | Détail |
|---|---|
| **v1.3.2 = DNS, v1.3.3 = CI, v1.4.0 = DNS central + PKI** | Thème unique « industrialisation autour de Gitea » ; la CI est décalée d'un cran |
| **v1.4.0 = DNS** | Nouvelle couche réseau ; mais le DNS du cluster est modeste et ne change pas d'architecture |

Aucune des deux n'a été confirmée. **Attention :** le document v1.3.1 déjà publié (et tagué) annonce la CI en v1.3.2. Il restera tel quel, selon la règle « tag publié = figé » ; l'écart sera noté dans la capitalisation de la prochaine version.

---

## 7. Feuille de route proposée (à confirmer)

```text
v1.3.0  fait    Gitea source de vérité
v1.3.1  fait    Dépôt de secours GitHub, rotation du PAT, contrôles PRA
v1.3.2  prévu   DNS Kubernetes du lab (variante A en premier livrable)
v1.3.3  prévu   Gitea Actions : runner, workflow minimal jusqu'à dev
v1.4.0  prévu   DNS central du lab, PKI, abandon progressif du hosts Windows
```

**Ce qui reste acquis pour la CI (section 2) :** DinD fonctionne, `docker run` et `docker build` fonctionnent, l'URL interne de Gitea est joignable. **Ce qui reste à faire :** le TLS vers le registre, le push, le runner, le workflow.

---

## 8. Plan d'implémentation proposé (v1.3.2, variante A)

Chaque étape est précédée d'un contrôle et suivie d'une validation ; une seule modification à la fois.

1. **Relever l'état de CoreDNS** : ConfigMap complète (sauvegardée dans un fichier hors Git), version, ressources. Lecture seule.
2. **Tester le TLS vers le registre** depuis un conteneur imbriqué (`--add-host gitea.local:172.18.0.2`, CA publique du lab copiée dans le pod jetable). Si `172.18.0.2:443` n'est pas joignable depuis le management, l'adresse cible est à revoir avant tout travail sur le DNS.
3. **Entrée CoreDNS** sur le cluster actuel : sauvegarde de la ConfigMap, dry-run, application, rechargement (le plugin `reload` est actif), puis résolution depuis un pod et depuis un conteneur imbriqué, **sans** `--add-host`.
4. **Plan de retour arrière** : restauration de la ConfigMap sauvegardée.
5. **Intégration au bootstrap** : script dédié sur le modèle de `configure-workload-registry.sh`, appelé avant la Root App, avec dry-run et contrôle.
6. **Contrôle du hosts Windows** dans le prévol : informatif.
7. **PRA complet** pour valider la reconstruction.
8. **Capitalisation** et tag.

---

## 9. Nettoyage à faire (laissé en l'état)

- **Namespace `ci-dind-test` et pod `dind-test`** : le pod privilégié existe toujours sur le cluster management. Il disparaîtra au prochain PRA, mais on peut le supprimer plus tôt :
  ```bash
  kubectl --context kind-gitops-management delete namespace ci-dind-test
  ```
- **`~/lab/tools/ci/dind-test.yaml`** : fichier local, hors Git. À conserver ou à ranger.
- **Nombre de runners** dans Gitea : toujours à relever.

---

## 10. Rappels et risques

- **Le pod de test était privilégié** : à supprimer après usage ; le runner définitif devra être épinglé par digest.
- **L'entrée du hosts Windows est utile et ne doit pas être supprimée** tant que le DNS global n'existe pas : le navigateur en dépend.
- **Toute modification du CoreDNS du management doit être rejouée à chaque PRA**, puisque le cluster est recréé. Elle doit donc être portée par le bootstrap ou par GitOps.
- **Limite inotify (512)** : ne pas créer de cluster Kind supplémentaire hors PRA.
- **Le fichier hosts Windows reste une dépendance implicite du poste** : le prévol l'indique mais ne la corrige pas.
- **Mode sinistre du prévol** (point hérité de la v1.3.1) : toujours non traité.

---

## 11. Fichiers et références

- `docs/gitops-lab-v1.3.1-cloturee-2026-10-08.md` : clôture de la v1.3.1.
- `scripts/configure-workload-registry.sh` : pose actuelle de `gitea.local → 172.18.0.2` sur les nœuds workload.
- `scripts/check-github-mirror.sh` : contrôle du dépôt de secours GitHub.
- `~/lab/tools/ci/dind-test.yaml` : manifeste du test DinD (hors Git).
- Adresses observées : management `172.18.0.2` ; Ingress dev `172.18.250.200` ; Ingress prod `172.18.255.200`.
