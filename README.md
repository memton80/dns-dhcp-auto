# Script de gestion automatique de BIND9 et d'ISC DHCP

## Automatic BIND9 and ISC DHCP Management Script

Un seul fichier Bash, sans aucune dépendance, qui installe **et surtout gère**
un serveur DNS (BIND9) et un serveur DHCP (ISC DHCP) sur Debian et Ubuntu.

Ce n'est pas un simple installateur : la configuration est conservée dans
`/etc/dns-dhcp-auto/config.conf` et le script sert ensuite de console
d'administration — services, zones, enregistrements, baux, réservations,
pare-feu, sauvegardes, diagnostic et désinstallation.

L'interface console est faite maison : ni `whiptail`, ni `dialog`, ni `python`.
Uniquement `bash`, les outils de base de la distribution, et un Tux animé
pendant les traitements.

---

## Table des matières / Table of Contents

- [Fonctionnalités](#fonctionnalités--features)
- [Ce que le script configure](#ce-que-le-script-configure--what-the-script-configures)
- [Prérequis](#prérequis--prerequisites)
- [Installation](#installation)
- [L'écran principal](#lécran-principal--main-screen)
- [Le menu Actions](#le-menu-actions--the-actions-menu)
- [Enregistrements DNS et réservations DHCP](#enregistrements-dns-et-réservations-dhcp--dns-records-and-dhcp-reservations)
- [Mode ligne de commande](#mode-ligne-de-commande--command-line-mode)
- [Fichiers produits](#fichiers-produits--generated-files)
- [Sauvegardes et restauration](#sauvegardes-et-restauration--backups-and-restore)
- [Désinstallation](#désinstallation--uninstallation)
- [Dépannage](#dépannage--troubleshooting)
- [Structure du projet](#structure-du-projet--project-structure)

---

## Fonctionnalités / Features

### Gestion, pas seulement installation / Management, not just installation

| | |
|---|---|
| **Installation** | Installe `bind9`, ses outils et `isc-dhcp-server` en suivant la progression réelle d'`apt` |
| **Configuration** | Un formulaire complet, replié par sections, couvrant tout ce que les deux services demandent |
| **Activation / désactivation** | Chacun des deux services s'active ou se coupe indépendamment, au démarrage comme tout de suite |
| **État permanent** | Panneau de droite : services, démarrage automatique, ports 53 et 67, pare-feu, nombre de zones et de baux |
| **Actions** | Démarrer, arrêter, redémarrer, recharger les zones, voir les baux, tester une résolution, lire les journaux |
| **Vérification** | `named-checkconf`, `named-checkzone` et `dhcpd -t` sont lancés avant tout redémarrage |
| **Sauvegardes** | Les fichiers en place sont copiés avant chaque écriture, et restaurables depuis le menu |
| **Diagnostic** | Un écran unique : état, ports en écoute, contrôles de configuration, résolution locale, dernières erreurs |
| **Désinstallation** | Depuis le menu, ou par le script autonome `uninstall-dns-dhcp.sh` généré à côté |

### Interface console / Console Interface

- Aucune dépendance : ni `whiptail`, ni `dialog`, ni `python`
- Français et anglais, choisis au premier lancement puis mémorisés
- Thème clair ou sombre, détecté depuis la couleur de fond du terminal (touche `t` pour basculer)
- Cadres Unicode, avec repli automatique en ASCII si le terminal n'est pas en UTF-8
- Redimensionnement du terminal pris en compte à chaud
- Tux marche au rythme de la progression réelle, et s'effondre si une étape échoue
- Chaque champ affiche son aide dans la barre du bas

---

## Ce que le script configure / What the script configures

### DNS — BIND9

| Réglage | Détail |
|---|---|
| Zone directe | `db.<domaine>`, SOA complet, NS, A du serveur |
| Zone inverse | Calculée depuis le réseau (`1.168.192.in-addr.arpa`), PTR générés automatiquement |
| Enregistrements | `A`, `AAAA`, `CNAME`, `MX`, `TXT`, `SRV`, `NS`, ajoutés depuis un sous-menu |
| Redirecteurs | Liste de serveurs, avec option « redirection seule » |
| Récursion | Activable, avec liste de clients autorisés (`localhost`, `localnets`, réseaux CIDR) |
| Transferts de zone | Liste d'autorisation, `none` par défaut |
| DNSSEC | Validation activable |
| IPv6 | Écoute activable |
| Discrétion | Version, nom d'hôte et identifiant de serveur masqués |
| Journalisation | Canal dédié vers `/var/log/named/named.log`, avec rotation |
| Temporisations | TTL, refresh, retry, expire et TTL négatif réglables |

Le numéro de série de chaque zone est au format `AAAAMMJJnn` et **augmente à chaque
écriture**, y compris plusieurs fois dans la même journée : les serveurs
secondaires voient toujours la mise à jour.

### DHCP — ISC DHCP

| Réglage | Détail |
|---|---|
| Étendue | Sous-réseau, masque, plage distribuée |
| Options | Passerelle, serveurs DNS, domaine, diffusion, serveurs NTP |
| Baux | Durée par défaut et durée maximale |
| Comportement | Serveur autoritaire, refus des clients inconnus |
| Réservations | Adresse fixe par adresse MAC, avec `A` et `PTR` créés dans le DNS |
| Démarrage PXE | `next-server` et `filename` |
| Interface | `INTERFACESv4` renseigné dans `/etc/default/isc-dhcp-server` |

### Mise à jour dynamique (DDNS)

Le serveur DHCP peut inscrire lui-même les baux dans les zones DNS. Le script
génère la clé partagée (`tsig-keygen`, algorithme au choix), l'inclut des deux
côtés et déclare les zones dans `dhcpd.conf`.

### Système

- Ouverture de `53/tcp`, `53/udp` et `67/udp` dans `ufw`
- `/etc/resolv.conf` pointé sur le serveur local, avec arrêt de `systemd-resolved`
- Sauvegarde systématique avant écriture
- Génération du script de désinstallation

---

## Prérequis / Prerequisites

- Debian 12 ou Ubuntu récent, avec `apt-get` et `iproute2`
- Un accès `root` (`sudo`)
- Un terminal d'au moins **76 × 20** caractères
- Une adresse IP fixe sur l'interface qui portera les services

> **ISC DHCP et Debian 13.** ISC DHCP a atteint sa fin de vie et le paquet
> `isc-dhcp-server` a été retiré des dépôts après Debian 12. Le script le
> détecte au lancement et le dit clairement : la partie DNS reste entièrement
> utilisable, mais la partie DHCP demande Debian 12 (ou un serveur Kea, hors
> périmètre de ce script).

---

## Installation

```bash
# 1. Récupérer le dépôt
sudo apt update && sudo apt install -y git
git clone https://github.com/memton80/dns-dhcp-auto.git
cd dns-dhcp-auto

# 2. Rendre le script exécutable
chmod +x manage-dns-dhcp.sh

# 3. Lancer la console de gestion
sudo ./manage-dns-dhcp.sh
```

Au premier lancement, le script demande la langue, pré-remplit les champs
depuis le réseau réel de la machine (interface, adresse, masque, passerelle,
réseau, zone inverse, plage DHCP) et n'écrit **rien** tant que `APPLIQUER`
n'a pas été choisi.

---

## L'écran principal / Main screen

```
┌────────────────────────────────────────────────────────────────────────────┐
│ * modifie          DNS-DHCP AUTO - GESTION BIND9 ET ISC DHCP        v1.0   │
└────────────────────────────────────────────────────────────────────────────┘
┌─ Configuration ─────────────────────────┐ ┌─ Machine et services ─────────┐
│  v SERVICES A GERER                     │ │ Nom d'hote   : srv.exemple.lan │
│     Activer BIND9 (DNS)      < OUI >    │ │ Adresse IP   : 192.168.1.5     │
│     Activer ISC DHCP         < OUI >    │ │ Pare-feu     : actif (ufw)     │
│     Demarrage automatique    < OUI >    │ │ BIND9        : demarre         │
│                                         │ │ ISC DHCP     : arrete          │
│  v RESEAU DE LA MACHINE                 │ │ Port 53 DNS  : named           │
│     Interface reseau         < eth0 >   │ │ Zones/baux   : 2 / 7           │
│     Adresse IP du serveur    192.168.1.5│ └───────────────────────────────┘
│     ...                                 │ ┌─ Raccourcis ──────────────────┐
└─────────────────────────────────────[v]─┘ └───────────────────────────────┘
┌────────────────────────────────────────────────────────────────────────────┐
│      [ APPLIQUER ]  [ ACTIONS ]  [ DIAGNOSTIC ]  [ QUITTER ]               │
└────────────────────────────────────────────────────────────────────────────┘
 Interface d'ecoute des services. Changer recharge IP et masque.
```

### Raccourcis clavier

| Touche | Effet |
|---|---|
| `↑` `↓` (ou `k` `j`) | Se déplacer |
| `←` `→` (ou `h` `l`) | Plier/déplier une section, basculer un oui/non, changer un choix, changer de bouton |
| `Entrée` | Modifier un champ, ouvrir une liste, activer un bouton |
| `Espace` | Basculer un oui/non |
| `a` | Menu des actions |
| `d` | Diagnostic complet |
| `s` | Enregistrer la configuration sans l'appliquer |
| `r` | Relire l'état de la machine |
| `t` | Thème clair / sombre |
| `q` ou `Échap` | Quitter (propose d'enregistrer si besoin) |

Un `* modifie` s'affiche en haut à gauche dès qu'un champ a changé sans avoir
été enregistré.

Les sections `DNS` disparaissent entièrement du formulaire si BIND9 est
désactivé, et les sections `DHCP` si ISC DHCP l'est : l'écran ne montre jamais
de réglages sans effet.

---

## Le menu Actions / The Actions menu

Touche `a`, ou bouton `[ ACTIONS ]`. Le menu s'adapte à ce qui est réellement
installé et en marche.

| Action | Effet |
|---|---|
| Appliquer la configuration | Installe ce qui manque, écrit tous les fichiers, vérifie, redémarre |
| Installer les paquets manquants | Seulement l'étape `apt` |
| Vérifier les fichiers de configuration | `named-checkconf`, `named-checkzone`, `dhcpd -t` |
| Diagnostic complet | État, ports, contrôles, résolution locale, journal |
| Démarrer / Arrêter / Redémarrer BIND9 | `systemctl` sur l'unité détectée (`named` ou `bind9`) |
| Recharger les zones DNS | `rndc reload`, sans coupure de service |
| Activer / Désactiver BIND9 au démarrage | `systemctl enable` / `disable` |
| Démarrer / Arrêter / Redémarrer ISC DHCP | idem pour `isc-dhcp-server` |
| Voir les baux DHCP | Lecture de `dhcpd.leases`, présentée en tableau |
| Gérer les enregistrements DNS | Sous-menu d'ajout, modification, suppression |
| Gérer les réservations DHCP | Sous-menu d'ajout, modification, suppression |
| Tester une résolution de nom | `dig` sur le serveur local |
| Journal de BIND9 / du serveur DHCP | `journalctl` filtré sur l'unité |
| Pare-feu | Ouvrir, fermer, ou consulter l'état d'`ufw` |
| Sauvegarder maintenant | Copie horodatée des fichiers en place |
| Restaurer une sauvegarde | Choix parmi les sauvegardes conservées |
| Recalculer depuis le réseau | Relit adresse, masque et passerelle de la machine |
| Remettre les valeurs par défaut | Réinitialise le formulaire, sans toucher aux fichiers |
| Désinstaller BIND9 et ISC DHCP | Arrêt, suppression des fichiers, purge des paquets au choix |

---

## Enregistrements DNS et réservations DHCP / DNS records and DHCP reservations

Les deux listes s'ouvrent avec `Entrée` depuis le formulaire, ou par le menu
des actions. Dans une liste :

| Touche | Effet |
|---|---|
| `Entrée` | Modifier l'entrée sélectionnée |
| `a` | Ajouter une entrée |
| `s` | Supprimer l'entrée sélectionnée |
| `Échap` | Fermer la liste |

La saisie est guidée et contrôlée : type d'enregistrement choisi dans une
liste fermée, adresse MAC normalisée (`-` converti en `:`), adresse IP vérifiée
comme appartenant au sous-réseau desservi, et avertissement si une réservation
tombe dans la plage distribuée dynamiquement.

Chaque réservation DHCP produit aussi son enregistrement `A` et son `PTR` :
une machine à adresse fixe se résout par son nom sans manipulation
supplémentaire.

---

## Mode ligne de commande / Command-line mode

Pratique pour une tâche planifiée ou un script d'infrastructure. Sans option,
c'est l'interface qui s'ouvre.

```bash
sudo ./manage-dns-dhcp.sh --status          # etat des services et des ports
sudo ./manage-dns-dhcp.sh --check           # controle des fichiers
sudo ./manage-dns-dhcp.sh --apply           # applique la configuration enregistree
sudo ./manage-dns-dhcp.sh --leases          # baux DHCP
sudo ./manage-dns-dhcp.sh --backup          # sauvegarde
sudo ./manage-dns-dhcp.sh --restart dns     # dns | dhcp | all
sudo ./manage-dns-dhcp.sh --disable dhcp
sudo ./manage-dns-dhcp.sh --help
```

`--apply` exige une configuration déjà enregistrée : lancez d'abord le script
sans option au moins une fois.

Variables d'environnement reconnues :

| Variable | Effet |
|---|---|
| `DDAUTO_LANG=fr\|en` | Force la langue et saute l'écran de choix |
| `DDAUTO_THEME=light\|dark` | Force le thème, sans interroger le terminal |

---

## Fichiers produits / Generated files

| Chemin | Contenu |
|---|---|
| `/etc/dns-dhcp-auto/config.conf` | Configuration enregistrée, en `clé=valeur`, jamais exécutée |
| `/etc/bind/named.conf.options` | Options de BIND9 |
| `/etc/bind/named.conf.local` | Journalisation et déclaration des zones |
| `/etc/bind/zones/db.<domaine>` | Zone directe |
| `/etc/bind/zones/db.<zone inverse>` | Zone inverse |
| `/etc/bind/ddns.key` | Clé de mise à jour dynamique, `640 root:bind` |
| `/etc/dhcp/dhcpd.conf` | Configuration du serveur DHCP |
| `/etc/default/isc-dhcp-server` | Interface d'écoute |
| `/var/log/named/named.log` | Journal dédié de BIND9 |
| `/var/log/dns-dhcp-auto.log` | Journal du script, `600 root` |
| `/var/backups/dns-dhcp-auto/` | Sauvegardes horodatées |
| `./uninstall-dns-dhcp.sh` | Script de désinstallation autonome |

Tous les fichiers générés commencent par la ligne
`# --- genere par dns-dhcp-auto ---` : rien de ce qui porte cette marque n'a
été écrit à la main.

---

## Sauvegardes et restauration / Backups and restore

Avant chaque application, les fichiers en place sont copiés dans
`/var/backups/dns-dhcp-auto/AAAAMMJJ-HHMMSS/`. Les **vingt** dernières
sauvegardes sont conservées, les plus anciennes sont effacées.

La restauration se fait depuis le menu des actions : la liste propose les
sauvegardes du plus récent au plus ancien, remet les fichiers en place et
recharge la configuration enregistrée. Les services ne sont pas redémarrés
automatiquement — c'est à vous de le faire une fois le résultat vérifié.

Une désinstallation **ne supprime pas** les sauvegardes.

---

## Désinstallation / Uninstallation

Depuis l'interface : `a` → `Désinstaller BIND9 et ISC DHCP`. Deux questions
sont posées : supprimer la configuration, puis purger ou non les paquets.

Sans l'interface, le script autonome généré à côté :

```bash
sudo ./uninstall-dns-dhcp.sh                  # avec confirmation
sudo ./uninstall-dns-dhcp.sh --yes            # sans question
sudo ./uninstall-dns-dhcp.sh --keep-packages  # garde bind9 et isc-dhcp-server
```

Il fige les chemins et les ports au moment où il a été généré : il reste
utilisable même si `manage-dns-dhcp.sh` a disparu de la machine.

---

## Dépannage / Troubleshooting

### « Le paquet isc-dhcp-server n'existe pas dans les dépôts »

La distribution est postérieure à Debian 12. Désactivez `Activer ISC DHCP`
dans la première section : la partie DNS fonctionne normalement.

### BIND9 ne démarre pas

```bash
sudo named-checkconf                       # syntaxe des fichiers
sudo systemctl status named --no-pager     # cause exacte
sudo ss -lunp | grep :53                   # qui occupe deja le port
```

La cause la plus fréquente est `systemd-resolved`, qui écoute déjà sur le
port 53. Le champ `Utiliser ce DNS` du formulaire l'arrête et redirige
`/etc/resolv.conf` vers le serveur local.

### Le serveur DHCP refuse de démarrer

```bash
sudo dhcpd -t -cf /etc/dhcp/dhcpd.conf
sudo systemctl status isc-dhcp-server --no-pager
```

`dhcpd` exige que la plage distribuée appartienne bien au sous-réseau déclaré
et que l'interface d'écoute porte une adresse dans ce sous-réseau. Le
formulaire vérifie déjà le premier point avant d'écrire.

### Les clients n'obtiennent pas d'adresse

```bash
sudo ./manage-dns-dhcp.sh --leases      # le serveur voit-il les demandes ?
sudo ufw status verbose                 # 67/udp est-il ouvert ?
```

Vérifiez également qu'aucun autre serveur DHCP (box, routeur) ne répond sur
le même réseau.

### La résolution ne marche que localement

Le champ `Clients autorisés` vaut `localhost;localnets` par défaut. Ajoutez le
réseau concerné en notation CIDR, par exemple `localhost;192.168.1.0/24`.

Éviter `any` avec la récursion activée : la machine devient un résolveur
ouvert, utilisable pour amplifier des attaques. Le script prévient avant
d'écrire une telle configuration.

### Le terminal affiche des caractères étranges

Le script bascule automatiquement en ASCII si le terminal n'est pas en UTF-8.
Pour forcer l'UTF-8 :

```bash
sudo LC_ALL=C.UTF-8 ./manage-dns-dhcp.sh
```

---

## Structure du projet / Project Structure

```
dns-dhcp-auto/
├── manage-dns-dhcp.sh     # le script, un seul fichier
├── README.md              # ce document
└── uninstall-dns-dhcp.sh  # genere a la premiere application
```

Le script suit le même découpage que `glpi-auto` : terminal et couleurs,
traductions, primitives de dessin, Tux, état de la machine, modèle du
formulaire, rendu, saisie, fenêtres modales, moteur d'étapes, tâches, actions,
boucle principale.
