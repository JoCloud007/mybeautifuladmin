# MyBeautifulAdmin

Console unifiée de **supervision et d'administration** pour une infra maison :
serveurs Linux, hyperviseurs Proxmox, NAS Synology, conteneurs Docker, services
web et endpoints Ollama — le tout **sans agent à installer**, via SSH et les API
natives de chaque plateforme.

```
┌─────────┐      ┌──────────────┐      ┌──────────────┐
│   web   │─────▶│     api      │─────▶│      db      │
│  nginx  │ /api │   FastAPI    │      │ TimescaleDB  │
│  React  │◀─ws─▶│  collecteurs │      │  hypertables │
└─────────┘      └──────┬───────┘      └──────────────┘
                        │ SSH · HTTPS · socket Docker
                        ▼
  Linux · Proxmox · PBS · Synology · Docker · Ollama
         BMC (IPMI) · Home Assistant
```

## Prérequis

Docker et Docker Compose v2. Rien d'autre : tout tourne en conteneur.

## Démarrage

```bash
cp .env.example .env
```

Génère les secrets et complète `.env` :

```bash
openssl rand -hex 32
```

à reporter dans `SECRET_KEY`, puis choisis un `POSTGRES_PASSWORD` et un
`ADMIN_PASSWORD`. `VAULT_KEY` peut rester vide : une clé est générée au premier
démarrage et conservée dans le volume `api_keys`.

```bash
docker compose up -d --build
```

L'interface est sur **http://localhost:8888**, l'API sur **http://localhost:8080**
(documentation interactive : `/docs`). Connecte-toi avec `ADMIN_USER` /
`ADMIN_PASSWORD` — le compte est créé au premier démarrage, change le mot de passe
depuis Réglages → Compte.

> **Sauvegarde le volume `api_keys`.** Il contient la clé de chiffrement du
> coffre : sans elle, tous les identifiants enregistrés deviennent illisibles.

## Premiers pas

1. **Réglages → Identifiants** : crée une clé SSH (ou un mot de passe), et un
   jeton d'API pour Proxmox.
2. **Découverte** : deux sources au choix.
   - *Réseau IP* : scan d'un sous-réseau. MBA sonde les ports caractéristiques
     (22, 8006, 5000/5001, 11434, 2375…), interroge les bannières SSH et les
     pages HTTP, devine le type de chaque machine.
   - *Tailscale* : liste complète du tailnet, via une clé d'API
     (`devices:read`) ou via `tailscale status --json` exécuté en SSH sur une
     machine déjà supervisée — sans clé à créer. Les tags ACL Tailscale
     deviennent des étiquettes MBA.

   Dans les deux cas, l'**adoption se fait en un clic**.
3. La collecte démarre immédiatement ; le tableau de bord se remplit en temps réel.

### Types d'identifiants

| Type | Champs | Pour quoi |
|---|---|---|
| Clé SSH | clé privée OpenSSH (+ phrase de passe) | serveurs Linux, hôtes Docker |
| Mot de passe | utilisateur + mot de passe (+ code OTP) | SSH, comptes DSM Synology |
| Jeton d'API | utilisateur + secret | Proxmox VE, Proxmox Backup Server |
| Jeton simple | secret seul | Home Assistant, Tailscale, API en Bearer |
| HTTP Basic | utilisateur + mot de passe | BMC, services web protégés |

**Jeton Proxmox** — l'erreur la plus fréquente. Dans Datacenter → Permissions →
API Tokens → Add : renseigne l'utilisateur (`root@pam`), un Token ID (`mba`), et
**décoche « Privilege Separation »** — sinon le jeton n'hérite d'aucun droit et
l'API répond 401. Copie le secret, il n'est affiché qu'une fois. Dans MBA, type
« Jeton d'API », utilisateur `root@pam!mba`, secret = l'UUID. Si tu laisses
« Privilege Separation » cochée, ajoute une API Token Permission sur le chemin `/`
avec le rôle `PVEAdmin`.

**Jeton Home Assistant** — profil (en bas à gauche) → Sécurité → « Créer un
jeton ». C'est un JWT en trois parties ; enregistre-le en type « Jeton simple ».

### Ce dont chaque type d'hôte a besoin

| Type | Port | Identifiants | Ce qui est collecté |
|---|---|---|---|
| Linux | 22 | clé SSH ou mot de passe | CPU (global + par cœur), RAM, swap, réseau, I/O disque, systèmes de fichiers, températures, GPU AMD, top processus, services systemd, mises à jour en attente |
| Proxmox | 8006 | jeton d'API `user@pam!nom` | charge des nœuds, inventaire VM/LXC, stockages, actions start/stop/reboot |
| Synology | 5001 | compte DSM administrateur | CPU, RAM, réseau, volumes, disques + SMART, paquets, partages |
| Docker | 22 | clé SSH | métriques système **et** conteneurs (CPU, RAM, ports, journaux) |
| IPMI/BMC | 443 (Redfish) | compte du contrôleur | alimentation, températures, ventilateurs, PSU, journal SEL |
| PBS | 8007 | jeton `user@pbs!id:secret` | datastores, groupes de sauvegarde, tâches, vérifications |
| Home Assistant | 8123 | jeton d'accès longue durée | entités par domaine, pilotage, batteries, disponibilité |
| Générique | au choix | — | disponibilité TCP |

L'hôte « Docker local » s'enregistre tout seul si le socket Docker est monté
(c'est le cas par défaut dans le `docker-compose.yml`).

> Le compte SSH doit pouvoir exécuter `reboot`, `apt-get upgrade`, `systemctl` et
> `docker` sans mot de passe pour que les actions correspondantes fonctionnent —
> typiquement `root`, ou un compte avec une règle `NOPASSWD` dans sudoers.

## Fonctionnalités

**Supervision temps réel.** Un seul WebSocket alimente toute l'interface. Les
graphiques sont dessinés par uPlot en dehors du cycle de rendu React : des
dizaines de séries à 5 points/seconde restent fluides. Historique conservé
14 jours en points bruts, avec agrégat continu à la minute pour les vues longues.

**Terminal.** Sessions SSH interactives en onglets (xterm.js), redimensionnement
propre, et shell direct **dans un conteneur** (`docker exec`) depuis n'importe
quelle carte de conteneur. Les sessions sont **persistantes** : le shell tourne
côté serveur MBA, pas dans le navigateur. Changer de page, verrouiller l'écran
ou perdre le réseau détache l'affichage sans interrompre ce qui s'exécute, et au
retour la sortie manquée est rejouée depuis un tampon de 256 Ko. La rétention
d'une session détachée se règle de 5 minutes à 24 heures, ou jusqu'à fermeture
explicite ; un panneau de préférences donne aussi la police, le corps,
l'interligne, le style de curseur et la profondeur d'historique, avec un aperçu
en direct et la liste des sessions vivantes sur le serveur.

**Actions.** Mise à jour des paquets avec sortie diffusée en direct, redémarrage,
extinction, contrôle des services systemd, start/stop/restart des conteneurs,
actions Proxmox sur les VM et LXC, reboot DSM, et gestion des paquets Synology —
démarrage, arrêt et **mise à jour** depuis le catalogue Synology.
Chaque action est confirmée, tracée et consultable dans **Journal → Actions**.

**Services web.** Sondes HTTP périodiques : disponibilité sur 24 h, latence,
historique des incidents, alerte au changement d'état.

**IA & accélérateurs.** Inventaire des modèles Ollama, modèles chargés et VRAM
occupée, téléchargement et déchargement, et un mode dialogue en flux avec compteur
de tokens/seconde. Les GPU AMD sont lus via sysfs : occupation, VRAM, GTT,
températures, fréquences et enveloppe de puissance. Sur un APU à **mémoire
unifiée** comme le Ryzen AI Max (Strix Halo), la carte affiche VRAM dédiée et GTT
partagée séparément, puisque c'est la RAM système qui sert de mémoire au GPU.

**Inventaire.** Le parc complet en une table : constructeur, modèle, numéro de
série, châssis, BIOS, processeur, mémoire, disques et adresses MAC sont relevés
automatiquement (DMI sur Linux, API DSM sur Synology, API sur Proxmox). Chaque
équipement se range dans une **catégorie**, reçoit un **emplacement**, des
**notes** et autant d'**étiquettes** que nécessaire. L'**adresse IP ou le nom DNS** se
corrigent depuis la fiche (la session SSH en cache est refermée pour repartir sur
la nouvelle cible). La **fiche technique est éditable champ par champ** : ta saisie prime sur le relevé, la valeur détectée
reste rappelée sous le champ, et vider la case rend la main à la détection. On y
ajoute aussi ce qu'aucune sonde ne connaît — code d'immobilisation, baie et
position U, fournisseur, prix, dates d'achat et de garantie. Sélection multiple
pour classer ou supprimer en masse, filtres cumulables, export CSV.

**Monitoring.** Une page dédiée en trois temps : un **mur temps réel** (toutes
les machines, densité réglable), une vue **comparaison** qui superpose plusieurs
hôtes sur la même métrique de 15 minutes à 30 jours, et un relevé **capteurs**
qui rassemble toutes les sondes du parc — thermal_zone et hwmon sur Linux, SMART
des disques, températures DSM, capteurs du BMC — avec seuils. Les
**ventilateurs** (`fan*_input` de tous les hwmon, plus ceux du GPU et du BMC) et
les **capteurs de puissance** sont relevés au même titre, filtrables par type et
traçables dans le temps.

**Sécurité.** Analyse de posture toutes les 15 minutes, sans scan intrusif :
correctifs de sécurité en attente, noyau installé mais non chargé, distributions
en fin de support, SSH permissif (root par mot de passe, mots de passe vides),
absence de pare-feu, ports sensibles en écoute (Docker 2375, Redis, bases de
données…), comptes UID 0 surnuméraires, disques en défaut SMART, services en
échec, certificats TLS expirés ou proches de l'être. Chaque constat porte une
sévérité, une explication et **la remédiation à appliquer** ; il se suit dans le
temps (apparu / toujours là / résolu) et peut être ignoré en connaissance de cause.
Score global et par machine.

**Proxmox.** Administration complète des invités : démarrage, arrêt propre ou
forcé, redémarrage, suspension, reset matériel — seules les actions cohérentes
avec l'état courant de l'invité sont proposées, et celles qui coupent le système
sans prévenir l'OS sont confirmées. La **console s'ouvre dans MBA**, en texte ou
en graphique : le navigateur n'a ni le jeton d'API ni un certificat PVE accepté,
l'API relaie donc `termproxy` vers un terminal xterm.js, et le flux **RFB** vers
un client noVNC dessiné dans la page. Une VM sans port série n'a pas de console
texte : MBA le détecte dans sa configuration et affiche directement son écran
graphique, souris et clavier compris, plutôt que l'erreur brute de Proxmox. Puis
**snapshots** (création avec ou sans RAM,
restauration, suppression) ; **sauvegardes** vzdump vers le stockage de ton choix
avec l'historique des archives ; **clonage** complet ou lié ; **migration** entre
nœuds, à chaud ou à froid ; ajustement des cœurs, de la mémoire et du démarrage
automatique ; historique CPU/RAM tiré des RRD de Proxmox ; suivi des tâches PVE
et lien direct vers la console noVNC. Un nœud déjà supervisé en SSH sur lequel
`/etc/pve` est détecté se bascule en un clic vers le collecteur dédié.

**Hors-bande (IPMI).** Pour les serveurs équipés d'un BMC — ASUS ASMB9/ASMB10-iKVM,
Supermicro, iDRAC, iLO. Deux transports : **Redfish** en HTTPS, ou **ipmitool**
exécuté depuis une machine relais du réseau quand le contrôleur est plus ancien.
Alimentation (allumage, arrêt ACPI, reset, cycle, coupure), capteurs thermiques
et ventilateurs, alimentations, consommation, journal matériel (SEL) et LED de
localisation — y compris quand le système est éteint. Le client s'adapte aux
particularités ASUS : racine Redfish avec ou sans slash, collections `Systems`
vides avec repli sur `/Systems/1` et `/Systems/Self`, identité lue depuis le
`Chassis`, LED portée par le châssis, et seules les actions d'alimentation
réellement déclarées par le BMC sont proposées.

**Protection des données.** Sources agrégées — **Proxmox Backup Server**
(datastores, groupes, vérifications), **vzdump** côté PVE, **Hyper Backup** côté
DSM et **Synology C2** repéré à travers les tâches Hyper Backup dont la
destination est C2. Hyper Backup est découvert automatiquement dès qu'un NAS est
enregistré : MBA interroge `SYNO.API.Info` pour savoir si le paquet est présent,
et explique clairement le contraire quand il ne l'est pas. La règle 3-2-1 est
vérifiée : sans copie hors site, un risque est levé. La page répond à deux questions : *qu'est-ce qui n'est pas sauvegardé* (VM,
conteneurs et machines absents de toute sauvegarde) et *quelles sauvegardes ne
sont plus fiables* (copie périmée, tâche désactivée ou en échec, version unique
conservée, datastore proche de la saturation, groupe jamais vérifié). Chaque
risque porte sa remédiation ; un taux de couverture résume l'ensemble.

**Domotique.** Home Assistant piloté par son API REST : entités regroupées par
domaine et repliables, bascule des lumières, prises, ventilateurs et
automatisations, déclenchement des scripts et scènes. La page met en avant ce qui
demande attention — entités indisponibles, batteries sous 20 %, automatisations
désactivées, mises à jour en attente. Les gestes non triviaux sont confirmés, et
seuls des services réversibles sont autorisés depuis MBA.

**Agents IA.** Des agents spécialisés — exploitation, mises à jour, sécurité,
sauvegardes, ou mission sur mesure — analysent l'état du parc via un modèle local
(Ollama) et proposent des corrections. Trois niveaux d'autonomie : **observation**
(analyse seule), **proposition** (chaque action attend une validation) et
**autonome** (les actions réversibles s'appliquent seules, le reste passe en file
d'attente). La liste blanche est vérifiée côté serveur, pas seulement dans
l'invite : redémarrer une machine ou recréer une pile compose reste soumis à
validation quel que soit le mode. Chaque exécution garde son contexte, son
raisonnement et le sort de chaque action ; un quota borne le nombre d'actions par
passage.

**Conteneurs.** Regroupement **par pile docker compose** (lu dans les labels
`com.docker.compose.*`) ou **par hôte**, avec actions sur toute une pile —
démarrer, arrêter, redémarrer d'un coup. Les groupes arrivent **repliés** : avec
des dizaines de piles, on voit d'abord la liste, puis on ouvre celle qui
intéresse — sauf pendant une recherche, où les résultats restent dépliés.
L'essentiel des ressources reste visible sur la ligne repliée, et une vue
**synthèse** donne
une ligne par pile : conteneurs actifs, CPU et RAM cumulés, images, ports. La **mise à jour** se fait à deux
niveaux : `docker pull` sur un conteneur pour récupérer sa dernière image, ou
`compose pull && up -d` sur toute une pile — seule voie sûre pour recréer des
conteneurs, puisque compose connaît leur configuration complète. Le **nettoyage
Docker** affiche d'abord ce qui est occupé et ce qui est récupérable, puis laisse
choisir quoi purger : les options sûres sont pré-cochées, celles qui détruisent
des données (volumes, images taguées) sont signalées et laissées décochées.

**Planificateur.** Maintenance récurrente en cron : mise à jour des paquets,
redémarrage, purge Docker, redémarrage d'un service ou d'un conteneur, commande
libre. La portée est un hôte, une **étiquette**, un type de machine, ou tout le
parc. Un aperçu affiche les cibles concernées et les prochains passages avant
d'enregistrer ; chaque exécution est journalisée et rejouable à la demande.

**Réseau.** Tous les équipements vus sur le réseau au même endroit : hôtes
supervisés, résultats de découverte et machines du tailnet, fusionnés et
dédoublonnés. Regroupement **par sous-réseau, étiquette, emplacement, type ou
catégorie** — les adresses Tailscale (`*.ts.net` et la plage CGNAT 100.64/10)
sont reconnues comme un réseau à part entière. Les ports ouverts sont traduits en
services lisibles (DSM, Proxmox, PBS, Ollama, Home Assistant…). Un onglet
**historique** retrace ce qui est apparu, ce qui a été détecté sans être adopté,
et la continuité de la collecte machine par machine — un trou dans les points
relevés révèle une coupure.

**Auto-remédiation.** Des règles qui corrigent d'elles-mêmes : *machine
injoignable*, *service web en panne*, *alerte déclenchée*, *constat de sécurité*,
*conteneur arrêté* ou *pression disque* déclenchent le redémarrage d'un service
ou d'un conteneur, une mise à jour, une purge Docker, une analyse par un agent IA
— ou une simple notification. La portée est un hôte, une étiquette, un type ou
tout le parc, et un aperçu montre les cibles concernées avant d'enregistrer.
Trois garde-fous encadrent chaque règle : un **délai de confirmation** (la
condition doit tenir, une panne d'une seconde ne déclenche rien), un **repos**
entre deux tentatives, et un **quota quotidien** qui empêche les rafales sur une
panne durable. Les actions destructives — redémarrer une machine — exigent une
autorisation explicite, cochée règle par règle ; sans elle, la règle refuse de
s'exécuter.

**Notifications.** Envoi par courriel (SMTP avec STARTTLS, SSL ou en clair),
configuré dans **Réglages → Notifications** et testable d'un bouton. Le mot de
passe est chiffré au même titre que les autres secrets. Chaque déclencheur
s'active séparément — machine injoignable ou de retour, alerte, service en panne,
constat de sécurité critique, risque de sauvegarde, action en échec, proposition
d'agent, remédiation appliquée — et un délai de silence évite qu'une panne
persistante ne remplisse la boîte mail.

**Une fiche par type de machine.** La page d'un hôte se compose à partir de ce
que la machine est réellement, pas d'un gabarit unique. Un contrôleur BMC n'a ni
processeur ni système de fichiers : sa fiche montre l'alimentation, la santé
matérielle, l'identité du serveur administré et ses capteurs — et dit clairement
quand le contrôleur n'en expose aucun, au lieu d'afficher des jauges à 0 %. Un
hôte joint par le seul socket Docker perd l'onglet historique système qu'il ne
peut pas remplir ; un NAS annonce « DSM & stockage ». Les actions suivent :
ni terminal ni `apt` sur un BMC, et « reset matériel » y remplace « redémarrer »,
puisque l'ordre court-circuite le système d'exploitation.

**iPhone et iPad.** L'interface est utilisable au doigt : la barre latérale
devient un tiroir sous 1024 px, l'en-tête se condense et rappelle la page
courante, les boîtes de dialogue s'ancrent en bas de l'écran à portée du pouce,
les tableaux larges défilent chez eux sans élargir la page. Les champs de
saisie passent à 16 px sur petit écran — en dessous, Safari zoome et ne revient
jamais — les cibles tactiles sont agrandies, et ce qui n'apparaissait qu'au
survol reste visible là où il n'y a pas de souris. Encoches et barres système
sont respectées via les zones sûres.

**Alertes.** Règles seuil + durée sur n'importe quelle métrique, avec résolution
automatique. Trois règles sont créées par défaut (CPU, RAM, disque).

## Développement

```bash
cd web && npm install && npm run dev     # front sur :5173, proxy vers :8080
docker compose up -d db api              # back
```

## Structure

```
api/app/
  poller.py        moteur de collecte (un worker asyncio par hôte)
  collectors/      linux · proxmox · synology · docker · ollama · tailscale
                   ipmi · pbs · homeassistant
  actions.py       upgrade / reboot / restart, tracés et diffusés
  audit.py         contrôles de sécurité et suivi des constats
  protection.py    couverture des sauvegardes, écarts et risques
  agents.py        agents IA : contexte, invite, garde-fous, exécution
  termsessions.py  shells SSH persistants : tampon, rattachement, expiration
  remediation.py   règles d'auto-remédiation : délai, repos, quota
  notify.py        notifications SMTP, déclencheurs et anti-rafale
  scheduler.py     ordonnanceur cron des actions de maintenance
  discovery.py     balayage TCP et empreinte des services
  migrations.py    évolutions de schéma idempotentes, jouées au démarrage
  bus.py           pub/sub in-process qui alimente le WebSocket
  routers/         API REST + WebSockets (flux, terminal, scan)
web/src/
  lib/live.ts      client WebSocket + tampons circulaires par métrique
  components/      graphiques uPlot, terminal, console noVNC,
                   palette de commandes ⌘K
  pages/           tableau de bord, inventaire, monitoring, réseau,
                   sécurité, sauvegardes, domotique, Proxmox, hors-bande,
                   conteneurs, agents IA, auto-remédiation, planificateur…
db/init/           schéma TimescaleDB initial
```

## Sécurité

Les secrets sont chiffrés en Fernet avant d'entrer en base et ne ressortent
jamais par l'API. L'authentification est un JWT (7 jours) accepté en en-tête
`Authorization` ou en cookie `HttpOnly`. Toute action d'administration est
confirmée dans l'interface et tracée dans le journal.

Deux limites assumées, à connaître avant de déployer :

* **Les clés d'hôtes SSH ne sont pas vérifiées.** Adapté à un réseau domestique
  maîtrisé, à revoir pour un usage exposé.
* **Les certificats TLS des équipements ne sont pas validés** (BMC, DSM, Proxmox
  utilisent des certificats auto-signés).

**N'expose pas cette console directement sur Internet.** Place-la derrière un VPN
(Tailscale fait très bien l'affaire) ou un reverse-proxy authentifié.

### Rien de sensible dans le dépôt

`.env` est ignoré par git, et le `.gitignore` couvre aussi les clés privées, les
dumps de base et les volumes de données. Avant un premier `git push`, vérifie :

```bash
git status --porcelain
```

Aucun `.env`, `*.key`, `*.pem` ni répertoire de données ne doit apparaître.

## Licence

Aucune licence n'est déclarée pour l'instant : ajoute-en une avant de rendre le
dépôt public si tu veux autoriser la réutilisation.
