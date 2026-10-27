# Pixelia : dossier de durcissement

Contexte A (agence web Pixelia), VM Debian 13. Les scripts reconstruisent la machine depuis le snapshot « vierge » et `verifier.sh` (50 tests, une fonction `test_<ID>_<objet>` par test) contrôle chaque exigence. Les références sont le guide ANSSI *Recommandations de configuration d'un système GNU/Linux* (BP-028) et le guide ANSSI *Usage sécurisé d'(Open)SSH*. Je les cite par thème, sans numéro de recommandation, parce que je n'ai pas vérifié les numéros un à un.

## 1. Tableau de conformité

| Exigence | Réalisation | Tests de `verifier.sh` | Référence |
|---|---|---|---|
| C1 comptes et groupes | `creer_comptes.sh` lit `comptes.csv`, idempotent ; freelance expirés au 31/01/2027 (`chage -E`) | `test_C1_comptes_du_csv`, `test_C1_sans_doublon`, `test_C1_freelance_expire` | BP-028, comptes |
| C2 droits sur `/srv` | `creer_comptes.sh` : `root:root`, mode 0770, ACL et ACL par défaut | `test_C2_projets`, `test_C2_externe`, `test_C2_maquettes`, `test_C2_clients`, `test_C2_acl_par_defaut`, `test_C2_proprietaire_et_mode` | BP-028, droits des fichiers |
| C3 sudo | `config/sudoers.d/10-admins` et `20-support` ; groupe `sudo` de Debian vidé par `installer.sh` | `test_C3_admins_sudo`, `test_C3_support_restreint`, `test_C3_aucun_autre_sudo`, `test_C3_chemin_sudo_protege` | BP-028, sudo |
| C4 root et homes | `passwd -l root`, homes en 0700 (`installer.sh`) | `test_C4_root_verrouille`, `test_C4_homes_prives` | BP-028, comptes |
| S1 clé seule | `config/ssh/sshd_config.d/10-pixelia.conf` | `test_S1_cle_seule` | guide OpenSSH |
| S2 root interdit | même fichier (`PermitRootLogin no`) | `test_S2_root_interdit` | guide OpenSSH |
| S3 `AllowGroups` | même fichier (`AllowGroups acces_ssh`) | `test_S3_allowgroups` | guide OpenSSH |
| S4 essais et inactivité | même fichier (`MaxAuthTries`, `ChannelTimeout`, `ClientAlive*`) | `test_S4_essais_et_inactivite` | guide OpenSSH |
| S5 drop-in validé | fichier dans `sshd_config.d/`, `sshd -t` avant le redémarrage (`installer.sh`) | `test_S5_config_dans_drop_in` | guide OpenSSH |
| J1 fail2ban | `config/fail2ban/jail.d/sshd-pixelia.conf` | `test_J1_fail2ban_actif`, `test_J1_valeurs_jail` | BP-028, journalisation |
| J2 pare-feu | `config/nftables.conf` : politique drop, SSH, connexions établies | `test_J2_politique_drop`, `test_J2_ssh_et_etablies`, `test_J2_au_demarrage`, `test_J2_regles_fail2ban_apres_rechargement` | BP-028, réseau |
| J3 journal persistant | `config/journald.conf.d/10-persistent.conf` | `test_J3_journal_persistant` | BP-028, journalisation |
| J4 analyse SSH | `analyse_logs.sh` ; journal d'exemple `tests/ssh_exemple_debian13.log` | `test_J4_seuil_depasse`, `test_J4_sous_le_seuil`, `test_J4_journal_vide`, `test_J4_pas_de_double_compte`, `test_J4_ip_dans_nom`, `test_J4_nom_piege`, `test_J4_proprietaire_root`, `test_J4_sshd_session`, `test_J4_support_sans_f` | BP-028, journalisation |
| D1 mises à jour | `config/apt/20auto-upgrades`, paquet `unattended-upgrades` | `test_D1_mises_a_jour_auto` | BP-028, mises à jour |
| D2 écoutes réseau | rien d'installé en dehors de SSH | `test_D2_seul_ssh_ecoute` | BP-028, services |
| D3 fichiers sensibles | SUID attendus listés dans `config/suid_attendus.txt` | `test_D3_aucun_fichier_modifiable_par_tous`, `test_D3_suid_connus` | BP-028, droits des fichiers |
| B1 versions | `sauvegarde.sh` : rsync, liens durs, 7 versions, ACL conservées | `test_B1_disque_monte`, `test_B1_versions_datees`, `test_B1_incrementale`, `test_B1_acl_conservees`, `test_B1_rotation`, `test_B1_verrou` | règle 3-2-1 du cours |
| B2 planification | `config/systemd/sauvegarde.service` et `.timer` (02:00), journal via `logger -t sauvegarde` | `test_B2_timer_actif`, `test_B2_journalisee` | règle 3-2-1 du cours |
| B3 accès | `/sauvegardes` en `root:root` 0700 | `test_B3_acces_admins` | BP-028, droits des fichiers |
| B4 restauration | procédure de la section 4 | `test_B4_restauration` | règle 3-2-1 du cours |

Écart de forme avec le sujet : les fonctions s'appellent `test_<ID>_<objet>` (plusieurs par exigence) au lieu de `test_<ID>`. La sortie suit le format demandé (`[OK] <ID>  <message>`, puis le total).

Pour D2, `ss -tulnH` montre SSH sur le port 22 (IPv4 et IPv6) et le client DHCP (UDP 68 et UDP 546). Le client DHCP n'attend pas de connexion entrante : il sert à obtenir l'adresse de la VM. Le test l'accepte et le dit dans son commentaire.

Pour D3, les fichiers SUID présents sont tous des outils standards de Debian :

| Fichier | Rôle |
|---|---|
| `dbus-daemon-launch-helper` | lance les services D-Bus système avec les bons droits |
| `ssh-keysign` | lit les clés d'hôte pour l'authentification par hôte |
| `fusermount3` | monte un système de fichiers FUSE sans être root |
| `mount`, `umount` | montent et démontent pour un utilisateur autorisé |
| `gpasswd` | gère les membres d'un groupe |
| `su` | change d'utilisateur |
| `chsh`, `chfn` | changent le shell et les informations de son propre compte |
| `sudo` | exécute une commande avec les droits d'un autre compte |
| `newgrp` | change de groupe principal pour la session |
| `passwd` | change son mot de passe (écrit `/etc/shadow`) |

## 2. Choix techniques

**SSH.** `MaxAuthTries 3`, sous le maximum de 4 du sujet : qui connaît sa clé n'a pas besoin de plus. Pour l'inactivité (15 minutes au plus), `ChannelTimeout session=10m` coupe une session sans trafic pendant 10 minutes. `ClientAliveInterval 300` avec `ClientAliveCountMax 1` coupe une connexion morte au bout de 300 x (1 + 1) = 600 s. Ce second réglage ne mesure pas l'inactivité, puisque le client répond tout seul aux messages. C'est `ChannelTimeout` qui porte l'exigence. La configuration est un drop-in dans `sshd_config.d/`, et `installer.sh` lance `sshd -t` avant de redémarrer ssh. L'installation SSH passe après la création des comptes : sinon `AllowGroups` viserait un groupe vide et nous laisserait dehors.

**fail2ban.** `maxretry = 5` en `findtime = 10m`, ban de 10 minutes. Cinq échecs laissent passer les fautes de frappe, et une durée courte limite le coût d'un faux positif (l'hôte de test se banne lui-même pendant les démonstrations). `actionstart_on_demand=false` crée la table `f2b-table` au démarrage de fail2ban et non au premier ban. Sans ce réglage, on ne pourrait pas tester que ses règles survivent à un rechargement du pare-feu avant d'avoir été attaqué. Le backend est `systemd`, car Debian 13 n'écrit plus `/var/log/auth.log`.

**Pare-feu.** `config/nftables.conf` ne contient pas `flush ruleset`, qui effacerait aussi `f2b-table` et lèverait tous les bans. Le fichier recrée seulement la table `inet filtre`. Le ping reste permis pour diagnostiquer le réseau.

**analyse_logs.sh.** Le seuil est de 5 échecs par adresse IP, repris de l'exercice 10 du TP, réglable avec `-s`. Le comptage se fait par connexion (un processus `sshd-session`), pas par ligne : une même tentative laisse parfois plusieurs lignes, et les compter toutes fausserait le seuil. Adresses et comptes sont lus dans le message de sshd lui-même, après l'étiquette `sshd-session[PID]`. Un attaquant choisit son nom d'utilisateur, et un nom qui imite une adresse ou une ligne d'échec ne doit pas tromper le rapport (`test_J4_nom_piege`). Le script refuse `-f` quand l'appelant sudo est `support` : la règle sudoers n'impose aucun argument, et `-f /etc/shadow` ferait lire à root un fichier choisi par `support`. Pour la même raison, le script appartient à root et n'est modifiable que par lui.

**Sauvegarde.** Sept versions, le minimum du sujet. Les liens durs de `rsync --link-dest` rendent la rétention peu coûteuse : sur la VM, une deuxième version pèse 736 Ko contre 5,4 Mo pour la première. Le passage a lieu à 02:00, hors des heures de travail, avec `Persistent=true` pour rattraper une VM éteinte. Un verrou `flock` empêche deux sauvegardes en même temps. La copie est écrite dans un dossier `.partielle`, renommé à la fin, pour qu'une sauvegarde interrompue ne laisse pas de fausse version, et la rotation ne supprime jamais la version qui vient d'être créée. Le point de montage est en `0700 root:root` : les admins y accèdent par sudo, personne d'autre.

**Droits et comptes.** Les freelance ont `--x` sur `/srv/projets` (traverser sans lister), sans quoi ils ne pourraient pas atteindre `/srv/projets/externe`, leur seul espace de travail. Cette traversée n'est pas dans l'ACL par défaut, pour que les futurs sous-projets restent fermés. Les comptes freelance expirent le 31/01/2027, fin du semestre. Les admins ont un mot de passe pour sudo, tandis que `support` n'en a pas pour son seul script. `ismail` n'a pas de mot de passe à l'installation, parce qu'aucun mot de passe n'a sa place dans le dépôt. Un admin le fixe ensuite avec `sudo passwd ismail`. Enfin, l'installateur ne retire le groupe `sudo` de Debian qu'après avoir vérifié qu'`ahmed` est dans `admins` et qu'il a un mot de passe utilisable.

## 3. Défense

**Force brute SSH.** Trois essais par connexion, clé obligatoire (le mot de passe n'est même pas proposé) et ban de l'adresse par fail2ban après 5 échecs.

**Vol de mot de passe.** Un mot de passe volé ne permet pas d'ouvrir une session SSH, qui n'accepte que les clés. Reste l'usage en local, d'où le verrou de root et l'absence de sudo en dehors des admins et du script de `support`.

**Utilisateur curieux.** Les homes sont en 0700 et `/srv` est fermé aux autres (`other:---`) : un commercial ne lit pas `/srv/projets` et n'écrit pas dans `/srv/maquettes`. Aucun fichier n'est modifiable par tous, et la liste des SUID est figée par un test.

**Compte freelance compromis.** Il n'a ni SSH, ni sudo, il expire au 31/01/2027, et il ne voit que `/srv/projets/externe`. Il ne lit pas `/sauvegardes`.

**Rançongiciel.** Un fichier chiffré ou supprimé reste intact dans les versions précédentes, ce que ne permettrait pas un miroir. Mais les sauvegardes sont sur le même serveur : un attaquant qui obtient root les efface aussi.

**Ce qui n'est pas couvert.**

- La sauvegarde est sur un disque de la même machine. Une panne de la VM, un vol ou un attaquant root la détruisent. En entreprise, il faudrait une copie sur un autre site.
- Le déclenchement du timer à 02:00 n'a pas été observé. Le service a été lancé à la main avec succès, et le timer est actif avec la bonne échéance.
- Un timer actif avec un service cassé n'est pas détecté : les tests n'appellent pas `systemd-analyze verify`.
- `installer.sh` écrit la ligne de `/etc/fstab` avec l'UUID et suppose de l'ext4. Un disque remplacé laisserait l'ancienne ligne en doublon.
- `rsync` renvoie le code 24 quand un fichier disparaît pendant la copie. Le script le traite comme un échec et ne garde pas la version.
- `systemctl restart nftables` efface `f2b-table` jusqu'au prochain redémarrage de fail2ban. Il faut utiliser `reload`, qui ne touche que notre table (cas couvert par `test_J2_regles_fail2ban_apres_rechargement`).
- `verifier.sh` lit la configuration SSH avec `sshd -T`. Un bloc `Match` ajouté plus tard ne serait vu que par `sshd -T -C ...`, que les tests n'appellent pas. Je n'ai pas non plus mesuré l'effet de `MaxAuthTries` sur un client qui présente plusieurs clés avec un agent SSH.
- `analyse_logs.sh` ne compte pas la ligne « Connection closed by authenticating user », pour éviter de compter deux fois une connexion déjà vue. Une connexion qui ne laisse que cette ligne n'apparaît donc pas dans les comptes visés.
- La recherche d'adresses IPv4 n'est pas validée : elle ne vérifie pas que chaque nombre est inférieur à 256.
- `find -xdev` (D3) ne descend pas dans `/sauvegardes`, qui est une autre partition réservée à root.
- Aucun des bonus n'est traité (Lynis, ssh-audit, MFA, AppArmor).

## 4. Procédure de restauration

Testée sur un fichier de `/srv/projets` créé par `jdupont`, sauvegardé, supprimé, puis restauré. Commandes à taper sur la VM, en tant qu'administrateur :

```
sudo ls /sauvegardes/versions/
sudo rsync -aAX /sauvegardes/versions/derniere/srv/projets/test-restauration.txt /srv/projets/
ls -l /srv/projets/test-restauration.txt
getfacl /srv/projets/test-restauration.txt
```

La première commande liste les versions datées (`AAAA-MM-JJ_HHMMSS`) et le lien `derniere`. Pour revenir à un état plus ancien, on remplace `derniere` par le nom d'une version. Pour un dossier entier, on donne le dossier. `cp -a` donne le même résultat que `rsync`.

Le fichier restauré est identique à l'original : propriétaire `jdupont`, groupe `dev`, mode `rw-rw----`, mêmes ACL (`group:dev:rwx`, `group:design:r-x`, `other::---`). Sans `-a`, le propriétaire redevient root, et sans `-A` les ACL sont perdues. `test_B4_restauration` rejoue cette vérification sur `srv/projets` : il restaure la dernière version dans un dossier temporaire, compare propriétaires, modes et ACL avec l'original, puis supprime le dossier.
