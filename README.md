# os_risk_diag.sh

Diagnostic pré-maintenance et post-panne pour cluster OpenSearch.
Identifie les shards à risque avant de mettre un ou plusieurs nœuds hors ligne,
et classe les shards `UNASSIGNED` selon leur récupérabilité réelle.
**Fonctionne aussi en cas de panne non planifiée** (perte de nœuds ou de zones).

**Lecture seule** — aucune modification du cluster.

---

## 📌 Changelog

| Version | Date       | Changements |
|---------|------------|-------------|
| **v1.1.0** | 2025-06-15 | **Détection automatique des pannes** : détection des nœuds/zones hors ligne sans option supplémentaire. **Fichiers CSV** (`index_summary.csv`, `shard_summary.csv`) pour analyse externe. **Synthèse console améliorée** avec hiérarchisation des messages (PERDU > STALE > ATTENTE_NOEUD > RISK). Correction des bugs (duplication de code, variables non initialisées). |
| v1.0.0 | 2025-06-01 | Version initiale : 5 étapes (découverte, filtrage, récupération, analyse, classification), checkpoints, cache TTL. |

---

## Prérequis

| Exigence | Détail |
|---|---|
| Shell | bash 4+ |
| Dépendances | `curl`, `awk` (POSIX), `sort`, `wc` — pas de `jq`, pas de Python |
| Accès réseau | HTTP(S) vers l'API OpenSearch |
| Droits OS | Lecture seule sur `_cat`, `_nodes`, `_cluster/state` |
| Attributs nœuds | `node.attr.zone` et `node.attr.temp` définis dans `opensearch.yml` |

---

## Configuration rapide

Éditer les lignes commentées en tête de script :

```bash
# Authentification
AUTH="-u admin:motdepasse"

# TLS auto-signé
CURL_OPTS="-k"

# Durée de validité du cache en secondes (défaut : 300)
CACHE_TTL=300
```

Les attributs `zone` et `temp` doivent être déclarés sur chaque nœud OpenSearch :

```yaml
# opensearch.yml
node.attr.temp: hot        # hot | warm | cold
node.attr.zone: az1        # az1 | az2 | az3
```

---

## Usage

```
./os_risk_diag.sh [host:port] [OPTIONS]
```

| Option | Description | Exemple |
|---|---|---|
| `host:port` | Hôte OpenSearch (défaut : `localhost:9200`) | `os-prod:9200` |
| `--temp` | Filtrer par attribut `node.attr.temp` | `--temp warm` |
| `--zone` | Filtrer par attribut `node.attr.zone` | `--zone az2` |
| `--log-dir` | Répertoire de sortie des logs (défaut : `/tmp/os_diag_...`) | `--log-dir /var/log/os_diag` |
| `--no-cache` | Forcer le re-fetch même si le cache est valide | `--no-cache` |
| `--resume` | Reprendre depuis le dernier checkpoint | `--resume` |

### Exemples

```bash
# Diagnostic complet sur tous les nœuds
./os_risk_diag.sh

# Nœuds warm uniquement (avant maintenance d'une tier)
./os_risk_diag.sh os-prod:9200 --temp warm

# Nœuds hot de la zone az1
./os_risk_diag.sh os-prod:9200 --temp hot --zone az1

# Forcer un rafraîchissement des données
./os_risk_diag.sh os-prod:9200 --temp warm --no-cache

# Reprendre une exécution interrompue
./os_risk_diag.sh os-prod:9200 --resume --log-dir /tmp/os_diag_20250615_143022_...
```

> **✨ Nouvelle fonctionnalité (v1.1.0)** : Le script **détecte automatiquement les nœuds/zones hors ligne** (ex. : en cas de panne). Aucune option supplémentaire n'est nécessaire.

---

## Déroulement

Le script s'exécute en **5 étapes séquentielles**, chacune protégée par un checkpoint
permettant la reprise en cas d'interruption.

```
ETAPE 1  Découverte des nœuds
         GET /_nodes?filter_path=nodes.*.name,nodes.*.attributes
         → Tableau nom / zone / temp de tous les nœuds du cluster
         → Détection automatique des nœuds/zones hors ligne (NOUVEAU en v1.1.0)

ETAPE 2  Filtrage des nœuds cibles
         → Sélection selon --temp et --zone
         → Inclusion des nœuds hors ligne dans l'analyse (NOUVEAU)
         → Liste des nœuds sur lesquels porte l'analyse

ETAPE 3  Récupération des données cluster
         GET /_cat/shards?h=index,shard,prirep,state,store,node,ip,segments.count
         GET /_cat/indices?h=index,pri,rep,docs.count,store.size,pri.store.size
         → Cache local des shards et volumétries

ETAPE 4  Analyse des risques  (awk pur, zéro fork en boucle)
         → Comptage des copies STARTED par shard dans tout le cluster
         → Classification : RISK / REPLICATING / UNASSIGNED / SAFE / NO_REPLICA
         → Volumétrie totale des index concernés

ETAPE 5  Classification des UNASSIGNED  (zéro appel HTTP supplémentaire)
         GET /_cluster/state/metadata,routing_table/{index_csv}
         → Croisement allocation_id × in_sync_allocations
         → Détection des index à 0 réplica (politique ISM)
         → Classification : ATTENTE_NOEUD / STALE / PERDU / NO_REPLICA
         → Génération des commandes de remédiation
         → Priorité aux nœuds hors ligne (NOUVEAU en v1.1.0)
```

---

## Fichiers de log produits

Chaque exécution crée un répertoire horodaté et paramétré :

```
/tmp/os_diag_20250615_143022_os-prod-9200_temp-warm_zone-az1/
```

| Fichier | Contenu | Criticité |
|---|---|---|
| `summary.log` | Résumé exécutif — go/no-go maintenance | ⭐ lire en premier |
| `risk_shards.log` | Shards en copie unique STARTED — perte certaine si nœud tombe | 🔴 bloquant |
| `remediation.log` | Commandes `curl` prêtes à exécuter pour STALE et PERDU | 🔴 si intervention |
| `unrecoverable_shards.log` | Classification ATTENTE / STALE / PERDU / NO_REPLICA | ⚠️ important |
| `norep_shards.log` | Shards sans réplica par politique ISM (non bloquants) | ℹ️ informatif |
| `replicating_shards.log` | Shards INITIALIZING — réplication en cours, pas encore protégés | ⚠️ attendre |
| `unassigned_shards.log` | Shards UNASSIGNED bruts (avant classification étape 5) | ⚠️ à classifier |
| `safe_shards.log` | Shards avec au moins une copie survivante ailleurs | ✅ OK |
| `index_volumes.log` | Volumétrie complète des index concernés (pri + total + docs) | ℹ️ informatif |
| `node_stats.log` | Nombre de shards et taille totale par nœud cible | ℹ️ informatif |
| `nodes.log` | Tableau des nœuds découverts et filtrés | ℹ️ informatif |
| `diagnostic.log` | Log complet de l'exécution (toutes étapes) | 🔍 debug |
| `errors.log` | Erreurs uniquement — vide si tout s'est bien passé | 🔍 debug |
| **`index_summary.csv`** | **Synthèse par index (CSV) — NOUVEAU en v1.1.0** | 📊 pour analyse externe |
| **`shard_summary.csv`** | **Détail par shard (CSV) — NOUVEAU en v1.1.0** | 📊 pour analyse externe |

---

## 📊 Fichiers CSV (NOUVEAU en v1.1.0)

Deux fichiers CSV sont générés pour faciliter l'analyse externe (Excel, Pandas, etc.) :

### `index_summary.csv`
Synthèse **par index** avec statut global, taille et nombre de shards par catégorie.

| Colonne | Description | Exemple |
|---|---|---|
| `index` | Nom de l'index | `mon-index-1` |
| `total_shards` | Nombre total de shards (pri + rep) | `10` |
| `shards_at_risk` | Shards en copie unique (RISK) | `2` |
| `shards_replicating` | Shards en réplication (INITIALIZING) | `1` |
| `shards_unassigned` | Shards non assignés | `3` |
| `shards_stale` | Shards STALE (copie périmée) | `1` |
| `shards_perdu` | Shards PERDU (perte totale) | `0` |
| `shards_norep` | Shards NO_REPLICA (ISM rep=0) | `2` |
| `total_size_gb` | Taille totale de l'index (GB) | `45.2` |
| `status` | Statut global (priorité au plus critique) | `RISK` |

**Exemple** :
```csv
index,total_shards,shards_at_risk,shards_replicating,shards_unassigned,shards_stale,shards_perdu,shards_norep,total_size_gb,status
mon-index-1,10,2,1,3,1,0,2,45.2,RISK
mon-index-2,5,0,0,0,0,5,0,12.5,PERDU
```

### `shard_summary.csv`
Détail **par shard** avec statut, priorité, taille et détails.

| Colonne | Description | Exemple |
|---|---|---|
| `index` | Nom de l'index | `mon-index-1` |
| `shard` | Numéro du shard | `0` |
| `role` | Rôle (p=primaire, r=réplica) | `p` |
| `status` | Statut (RISK, SAFE, REPLICATING, UNASSIGNED, ATTENTE_NOEUD, STALE, PERDU, NO_REPLICA) | `RISK` |
| `priority` | Priorité (1=critique, 4=OK) | `1` |
| `state` | État actuel (STARTED, INITIALIZING, UNASSIGNED) | `STARTED` |
| `copies_started` | Nombre de copies STARTED dans le cluster | `1` |
| `copies_init` | Nombre de copies INITIALIZING | `0` |
| `node` | Nœud hébergeant le shard | `node-az1-01` |
| `ip` | Adresse IP du nœud | `10.0.0.1` |
| `size_gb` | Taille du shard (GB) | `22.5` |
| `details` | Explication du statut | `Copie unique - perte si node-az1-01 tombe` |

**Exemple** :
```csv
index,shard,role,status,priority,state,copies_started,copies_init,node,ip,size_gb,details
mon-index-1,0,p,RISK,1,STARTED,1,0,node-az1-01,10.0.0.1,22.5,"Copie unique - perte si node-az1-01 tombe"
mon-index-1,1,r,SAFE,4,STARTED,2,0,node-az2-01,10.0.0.2,22.5,"2 copies STARTED - safe"
mon-index-2,0,p,PERDU,1,UNASSIGNED,0,0,,,10.5,"Aucun allocation_id dans routing_table"
```

> **💡 Utilisation** : Ces fichiers peuvent être ouverts dans **Excel**, **Pandas** (Python), ou tout autre outil d'analyse.

---

## Classification des shards

### Étape 4 — Risque sur les nœuds cibles

| Tag | Signification | Action |
|---|---|---|
| `RISK` | Shard STARTED en copie unique sur un nœud cible | ⛔ Bloquer la maintenance |
| `REPLICATING` | Shard INITIALIZING — réplication en cours | ⏳ Attendre la fin |
| `UNASSIGNED` | Shard non assigné sans réplication active | → Étape 5 |
| `SAFE` | Au moins une copie STARTED sur un autre nœud | ✅ Maintenance possible |
| `NO_REPLICA` | Réplica d'un index avec `number_of_replicas=0` (ISM) | ℹ️ Normal, non bloquant |

### Étape 5 — Récupérabilité des UNASSIGNED

La classification repose sur le croisement entre :
- **`routing_table`** : `allocation_id` du shard sur le nœud absent
- **`in_sync_allocations`** : liste des IDs de copies considérées valides par le cluster
- **Détection des nœuds hors ligne** (NOUVEAU en v1.1.0) : priorité aux shards liés à des nœuds en panne.

```
allocation_id  ∈  in_sync_allocations  →  ATTENTE_NOEUD
allocation_id  ∉  in_sync_allocations  →  STALE
allocation_id  absent (NONE)           →  PERDU
number_of_replicas = 0  +  role = r   →  NO_REPLICA  (ISM)
```

| Catégorie | Signification | Action |
|---|---|---|
| `ATTENTE_NOEUD` | Copie valide sur le nœud absent — recovery automatique au retour | ✅ Rien à faire |
| `STALE` | Copie présente mais périmée (`hors in_sync`) | ⚠️ `allocate_stale_primary` + `accept_data_loss` |
| `PERDU` | Aucune copie valide connue dans les métadonnées | 🔴 `allocate_empty_primary` + `accept_data_loss` |
| `NO_REPLICA` | `number_of_replicas=0` par politique ISM, réplica UNASSIGNED voulu | ℹ️ Normal, non bloquant |

> **Note** : un shard **primaire** UNASSIGNED avec `number_of_replicas=0` est toujours
> analysé normalement — c'est la seule copie de la donnée.

---

## 🚨 Gestion des Pannes (NOUVEAU en v1.1.0)

Le script **détecte automatiquement les nœuds et zones hors ligne** et adapte son analyse :

### Détection des Pannes
- **Nœuds hors ligne** : Comparaison du nombre de nœuds par zone pour identifier les nœuds manquants.
- **Zones hors ligne** : Si une zone n'a **aucun nœud en ligne**, elle est marquée comme hors ligne.
- **Noms hypothétiques** : Si une zone a moins de nœuds que les autres, le script génère des noms de nœuds hypothétiques (ex. : `node-az1-01`, `node-az1-02`).

### Classification Adaptée
- Les shards `UNASSIGNED` dont le `allocation_id` est lié à un **nœud hors ligne** sont :
  - Classés en **`ATTENTE_NOEUD`** si `alloc_id ∈ in_sync_allocations` (recovery auto au retour).
  - Classés en **`STALE`** si `alloc_id ∉ in_sync_allocations` (copie périmée).
- Les shards **`PERDU`** (aucune copie valide) sont **mis en avant** dans la synthèse.

### Synthèse Console en Mode Panne
En cas de panne détectée, la sortie console est **hiérarchisée** pour prioriser les actions :

```
 🚨 PANNE DÉTECTÉE
   Zones hors ligne : az1
   Nœuds hors ligne : node-az1-01,node-az1-02

 🔴 PERTE DE DONNÉES DÉTECTÉE
   5 shard(s) PERDU → Aucune copie valide connue
   Volume perdu : 25.3 GB
   Actions :
     1. Vérifier les snapshots : GET /_snapshot/_all
     2. Exécuter remediation.log (accept_data_loss=true)

 ⚠️  RÉCUPÉRATION NÉCESSAIRE (STALE)
   2 shard(s) STALE → Copie périmée sur disque
   Actions :
     - Exécuter remediation.log (allocate_stale_primary)

 ℹ️  RÉCUPÉRATION AUTOMATIQUE (ATTENTE_NOEUD)
   10 shard(s) ATTENTE_NOEUD → Recovery auto au retour des nœuds
   Actions :
     - Redémarrer les nœuds hors ligne

 ❌ MAINTENANCE IMPOSSIBLE : Perte de données détectée (shards PERDU)
```

---

## Commandes de remédiation

Le fichier `remediation.log` contient des commandes `curl` prêtes à l'emploi pour
les shards STALE et PERDU. Remplacer `NOEUD_CIBLE` par le nom du nœud de destination.

```bash
# Shard STALE — copie périmée sur disque (perte partielle possible)
curl -ku admin:admin -X POST "http://os-prod:9200/_cluster/reroute" \
  -H "Content-Type: application/json" \
  -d '{"commands":[{"allocate_stale_primary":{"index":"mon-index","shard":0,"node":"NOEUD_CIBLE","accept_data_loss":true}}]}'

# Shard PERDU — réinitialisation à vide (perte totale)
curl -ku admin:admin -X POST "http://os-prod:9200/_cluster/reroute" \
  -H "Content-Type: application/json" \
  -d '{"commands":[{"allocate_empty_primary":{"index":"mon-index","shard":0,"node":"NOEUD_CIBLE","accept_data_loss":true}}]}'
```

**⚠️ Ces commandes impliquent `accept_data_loss: true`. Les exécuter uniquement
après avoir confirmé qu'aucune autre copie n'est disponible (snapshot, autre cluster).**

---

## Reprise sur erreur

Le script écrit un checkpoint à chaque étape dans `cache/checkpoint`.
En cas d'interruption réseau ou timeout, relancer avec `--resume` :

```bash
# Reprise automatique du dernier run
./os_risk_diag.sh os-prod:9200 --resume

# Reprise d'un run spécifique
./os_risk_diag.sh os-prod:9200 --resume \
  --log-dir /tmp/os_diag_20250615_143022_os-prod-9200_temp-warm
```

Les données déjà fetchées (shards, cluster state, indices) sont relues depuis le cache
sans nouvel appel HTTP. La durée de validité du cache est configurable via `CACHE_TTL`.

---

## Optimisations

| Problème | Solution |
|---|---|
| 14 000+ shards — boucles shell lentes | Analyse étape 4 et 5 en `awk` pur, zéro fork en boucle |
| N appels HTTP pour N index | Un seul `GET /_cluster/state/.../idx1,idx2,...` pour tous |
| Parsing JSON sans `jq` | `awk` POSIX avec `gsub` — compatible mawk, nawk, awk BSD |
| Interruption réseau | Cache fichier TTL + checkpoints + `--resume` |
| Locale décimale (`fr_FR`) | `LC_ALL=C` forcé en tête de script |
| Variables perdues dans un pipe | Compteurs `awk` écrits dans un fichier, lus par `read` |
| **Détection des pannes** | **Détection automatique des nœuds/zones hors ligne (NOUVEAU)** |

---

## Décision de maintenance

```
summary.log dit...                Action
────────────────────────────────────────────────────────────
✅ Aucun shard à risque           Maintenance possible
🔴 N shards PERDU                Vérifier snapshots avant tout
🔴 N shards en copie unique       Bloquer — répliquer d'abord
⚠️  N shards STALE                Décider accept_data_loss avant
⚠️  N shards REPLICATING          Attendre la fin de la réplication
ℹ️  N shards NO_REPLICA           Normal si ISM impose rep=0
```

### Séquence recommandée avant maintenance

```bash
# 1. Lancer le diagnostic
./os_risk_diag.sh os-prod:9200 --temp warm --zone az2

# 2. Lire le résumé
cat /tmp/os_diag_.../summary.log

# 3a. Si RISK > 0 : augmenter les replicas et attendre
curl -ku admin:admin -X PUT "http://os-prod:9200/mon-index/_settings" \
  -H "Content-Type: application/json" \
  -d '{"index.number_of_replicas": 1}'

# 3b. Attendre le cluster green
curl -ku admin:admin \
  "http://os-prod:9200/_cluster/health?wait_for_status=green&timeout=10m"

# 4. Désactiver la réallocation pendant la maintenance
curl -ku admin:admin -X PUT "http://os-prod:9200/_cluster/settings" \
  -H "Content-Type: application/json" \
  -d '{"persistent":{"cluster.routing.allocation.enable":"none"}}'

# 5. Flush avant arrêt du nœud
curl -ku admin:admin -X POST "http://os-prod:9200/_flush"

# --- maintenance ---

# 6. Réactiver après remise en service
curl -ku admin:admin -X PUT "http://os-prod:9200/_cluster/settings" \
  -H "Content-Type: application/json" \
  -d '{"persistent":{"cluster.routing.allocation.enable":null}}'

# 7. Relancer le diagnostic pour confirmer
./os_risk_diag.sh os-prod:9200 --temp warm --zone az2 --no-cache
```

---

## Appels API utilisés

| API | Étape | Usage |
|---|---|---|
| `GET /_nodes?filter_path=...` | 1 | Découverte nœuds + attributs |
| `GET /_cat/shards?h=...` | 3 | Liste complète des shards |
| `GET /_cat/indices?h=...` | 3 | Volumétrie et nombre de réplicas |
| `GET /_cluster/state/metadata,routing_table/{index_csv}` | 5 | `in_sync_allocations` + `allocation_id` |
