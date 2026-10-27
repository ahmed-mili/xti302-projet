#!/usr/bin/env bash
#
# verifier.sh : prouve, exigence par exigence, que la VM est conforme au sujet.
#
# Usage : sudo ./verifier.sh
#
# Le script ne modifie jamais le système. Il affiche une ligne [OK] ou [KO]
# par test, puis un bilan, et rend le code 0 (tout est conforme) ou 1 (au
# moins un test échoue). Le code 2 signifie un mauvais usage du script.
#
# Pas de "set -e" ici : un test qui échoue ne doit pas arrêter les suivants.
set -u

# Dossier du dépôt : les tests liront comptes.csv, tests/ et config/ depuis là,
# quel que soit le dossier d'où le script est lancé.
DOSSIER_DEPOT="$(cd "$(dirname "$0")" && pwd)"

# Compteurs du bilan : nombre de tests passés et nombre de tests réussis.
NB_TESTS=0
NB_OK=0

# ---------------------------------------------------------------------------
# Affichage des résultats
# ---------------------------------------------------------------------------

# ok <ID> <message> : enregistre un test réussi.
ok() {
    NB_TESTS=$((NB_TESTS + 1))
    NB_OK=$((NB_OK + 1))
    echo "[OK] $1  $2"
}

# ko <ID> <message> : enregistre un test échoué.
ko() {
    NB_TESTS=$((NB_TESTS + 1))
    echo "[KO] $1  $2"
}

# ---------------------------------------------------------------------------
# Outils de test (utilisés par les fonctions test_<ID>_<objet>)
# ---------------------------------------------------------------------------

# peut_lire <login> <chemin> : renvoie 0 si l'utilisateur peut lire le chemin.
# Pour un répertoire, lire ne suffit pas : il faut aussi pouvoir le traverser (x).
peut_lire() {
    local login="$1"
    local chemin="$2"

    if [ -d "$chemin" ]; then
        sudo -u "$login" test -r "$chemin" 2>/dev/null && sudo -u "$login" test -x "$chemin" 2>/dev/null
    else
        sudo -u "$login" test -r "$chemin" 2>/dev/null
    fi
}

# peut_ecrire <login> <répertoire> : renvoie 0 si l'utilisateur peut créer un
# fichier dans le répertoire. On essaie vraiment de créer un fichier (c'est la
# seule preuve fiable avec les ACL), puis on le supprime aussitôt.
peut_ecrire() {
    local login="$1"
    local repertoire="$2"
    local fichier_temporaire="${repertoire}/verif_${login}_$$"

    if sudo -u "$login" touch "$fichier_temporaire" 2>/dev/null; then
        rm -f "$fichier_temporaire"
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# Outils propres aux tests C (comptes, droits, sudo)
# ---------------------------------------------------------------------------

# Fichier des comptes, lu par plusieurs tests.
FICHIER_COMPTES="${DOSSIER_DEPOT}/comptes.csv"

# logins_du_groupe <groupe> : affiche les logins de comptes.csv dont le groupe
# principal est <groupe> (colonne 3), un par ligne. NR > 1 saute l'en-tête.
logins_du_groupe() {
    awk -F';' -v groupe="$1" 'NR > 1 && $1 != "" && $3 == groupe { print $1 }' "$FICHIER_COMPTES"
}

# acces_reel <login> <répertoire> : affiche ce que l'utilisateur peut vraiment
# faire dans le répertoire. On teste les trois droits séparément :
#   r = lister le contenu, x = traverser, w = créer un fichier.
# Résultat : "rw" (r, x et w), "r" (r et x sans w), "x" (traverser seulement :
# ni lister ni créer), "-" (aucun des trois). Toute autre combinaison est
# affichée telle quelle (par exemple "bizarre:rx") et fera échouer le test.
acces_reel() {
    local login="$1"
    local repertoire="$2"
    local lettres=""

    if sudo -u "$login" test -r "$repertoire" 2>/dev/null; then
        lettres="${lettres}r"
    fi
    if sudo -u "$login" test -x "$repertoire" 2>/dev/null; then
        lettres="${lettres}x"
    fi
    if peut_ecrire "$login" "$repertoire"; then
        lettres="${lettres}w"
    fi

    case "$lettres" in
        rxw) echo "rw" ;;
        rx)  echo "r" ;;
        x)   echo "x" ;;
        "")  echo "-" ;;
        *)   echo "bizarre:${lettres}" ;;
    esac
}

# Liste des écarts trouvés par comparer_groupe (vidée par verifier_repertoire).
ECARTS=""

# comparer_groupe <répertoire> <groupe> <accès attendu> : compare l'accès réel
# de chaque membre du groupe (d'après comptes.csv) avec l'accès attendu et note
# les différences dans ECARTS.
comparer_groupe() {
    local repertoire="$1"
    local groupe="$2"
    local attendu="$3"
    local login
    local reel

    for login in $(logins_du_groupe "$groupe"); do
        reel="$(acces_reel "$login" "$repertoire")"
        if [ "$reel" != "$attendu" ]; then
            ECARTS="${ECARTS} ${login}(attendu ${attendu}, obtenu ${reel})"
        fi
    done
}

# verifier_repertoire <ID> <répertoire> <dev> <design> <commercial> <freelance> :
# compare l'accès réel de chaque groupe avec l'accès attendu (rw, r, x ou -)
# et affiche un seul [OK] ou [KO] pour le répertoire.
verifier_repertoire() {
    local id="$1"
    local repertoire="$2"

    ECARTS=""
    comparer_groupe "$repertoire" dev "$3"
    comparer_groupe "$repertoire" design "$4"
    comparer_groupe "$repertoire" commercial "$5"
    comparer_groupe "$repertoire" freelance "$6"

    if [ -z "$ECARTS" ]; then
        ok "$id" "${repertoire} : droits conformes au tableau"
    else
        ko "$id" "${repertoire} :${ECARTS}"
    fi
}

# ---------------------------------------------------------------------------
# C1 : comptes et groupes
# ---------------------------------------------------------------------------

# problemes_du_compte <login> <groupe principal> <groupes secondaires> :
# affiche une ligne par problème trouvé (compte absent, mauvais groupe).
# Les groupes secondaires sont séparés par des virgules ; tr les remplace
# par des espaces pour pouvoir les parcourir avec for.
problemes_du_compte() {
    local login="$1"
    local principal="$2"
    local secondaires="$3"
    local groupe

    if ! id "$login" >/dev/null 2>&1; then
        echo "${login}(compte absent)"
        return
    fi
    if [ "$(id -gn "$login")" != "$principal" ]; then
        echo "${login}(groupe principal différent de ${principal})"
    fi
    for groupe in $(echo "$secondaires" | tr ',' ' '); do
        if ! id -nG "$login" | tr ' ' '\n' | grep -qx "$groupe"; then
            echo "${login}(pas dans ${groupe})"
        fi
    done
}

# test_C1_comptes_du_csv : chaque login de comptes.csv existe et appartient à
# son groupe principal et à ses groupes secondaires.
test_C1_comptes_du_csv() {
    local manquants
    local login _nom principal secondaires

    if [ ! -f "$FICHIER_COMPTES" ]; then
        ko "C1" "comptes.csv introuvable"
        return
    fi

    # tail -n +2 saute l'en-tête, tr retire d'éventuels retours chariot, la
    # boucle affiche une ligne par problème et $( ) récupère tout ce texte
    # dans la variable (une boucle placée après un | ne peut pas modifier les
    # variables du script, d'où cette façon de faire).
    manquants="$(tail -n +2 "$FICHIER_COMPTES" | tr -d '\r' | while IFS=';' read -r login _nom principal secondaires || [ -n "$login" ]; do
        if [ -n "$login" ]; then
            problemes_du_compte "$login" "$principal" "$secondaires"
        fi
    done | tr '\n' ' ')"

    if [ -z "$manquants" ]; then
        ok "C1" "tous les comptes de comptes.csv existent avec leurs groupes"
    else
        ko "C1" "comptes ou groupes manquants :${manquants}"
    fi
}

# test_C1_sans_doublon : aucun login ni aucun groupe n'apparaît deux fois.
# (La relance de installer.sh est testée à la main : verifier ne modifie rien.)
test_C1_sans_doublon() {
    local logins_doubles
    local groupes_doubles

    logins_doubles="$(cut -d: -f1 /etc/passwd | sort | uniq -d)"
    groupes_doubles="$(cut -d: -f1 /etc/group | sort | uniq -d)"

    if [ -z "$logins_doubles" ] && [ -z "$groupes_doubles" ]; then
        ok "C1" "aucun login ni groupe en double"
    else
        ko "C1" "doublons : ${logins_doubles} ${groupes_doubles}"
    fi
}

# test_C1_freelance_expire : les comptes du groupe freelance expirent le
# 31 janvier 2027 (fin du semestre).
test_C1_freelance_expire() {
    local mauvais=""
    local login

    for login in $(logins_du_groupe freelance); do
        if ! LC_ALL=C chage -l "$login" 2>/dev/null | grep -q "Account expires.*: Jan 31, 2027"; then
            mauvais="${mauvais} ${login}"
        fi
    done

    if [ -z "$(logins_du_groupe freelance)" ]; then
        ko "C1" "aucun compte freelance dans comptes.csv"
    elif [ -z "$mauvais" ]; then
        ok "C1" "les comptes freelance expirent le 31 janvier 2027"
    else
        ko "C1" "date d'expiration absente ou fausse :${mauvais}"
    fi
}

# ---------------------------------------------------------------------------
# C2 : droits sur /srv
# ---------------------------------------------------------------------------

# Les quatre tests suivants comparent le tableau du sujet :
#                      dev  design  commercial  freelance
test_C2_projets()   { verifier_repertoire "C2" /srv/projets         rw r  -  x; }
test_C2_externe()   { verifier_repertoire "C2" /srv/projets/externe rw r  -  rw; }
test_C2_maquettes() { verifier_repertoire "C2" /srv/maquettes       r  rw r  -; }
test_C2_clients()   { verifier_repertoire "C2" /srv/clients         -  -  rw -; }

# acl_defaut_conforme <répertoire> <entrées attendues...> : vrai si les ACL par
# défaut des groupes nommés du répertoire sont exactement celles de la liste
# (par exemple "default:group:dev:rwx"). On trie les deux listes pour que
# l'ordre n'ait pas d'importance.
acl_defaut_conforme() {
    local repertoire="$1"
    local attendu
    local reel

    shift
    attendu="$(printf '%s\n' "$@" | sort)"
    reel="$(getfacl -p "$repertoire" 2>/dev/null | grep '^default:group:[a-z]' | sort)"
    [ "$attendu" = "$reel" ]
}

# test_C2_acl_par_defaut : chaque répertoire a exactement les ACL par défaut
# prévues, afin que les nouveaux fichiers gardent les bons droits. Les ACL par
# défaut reprennent les droits d'accès, sauf freelance sur /srv/projets : il
# n'a qu'un droit de traverser, qui n'a aucun sens pour de futurs fichiers.
test_C2_acl_par_defaut() {
    local fausses=""

    if ! acl_defaut_conforme /srv/projets "default:group:dev:rwx" "default:group:design:r-x"; then
        fausses="${fausses} /srv/projets"
    fi
    if ! acl_defaut_conforme /srv/projets/externe "default:group:dev:rwx" "default:group:design:r-x" "default:group:freelance:rwx"; then
        fausses="${fausses} /srv/projets/externe"
    fi
    if ! acl_defaut_conforme /srv/maquettes "default:group:dev:r-x" "default:group:design:rwx" "default:group:commercial:r-x"; then
        fausses="${fausses} /srv/maquettes"
    fi
    if ! acl_defaut_conforme /srv/clients "default:group:commercial:rwx"; then
        fausses="${fausses} /srv/clients"
    fi

    if [ -z "$fausses" ]; then
        ok "C2" "ACL par défaut conformes sur les quatre répertoires"
    else
        ko "C2" "ACL par défaut différentes de celles prévues sur :${fausses}"
    fi
}

# test_C2_proprietaire_et_mode : propriétaire root:root et mode 770 (donc rien
# pour "other") ; les ACL donnent ensuite les droits aux groupes.
test_C2_proprietaire_et_mode() {
    local mauvais=""
    local repertoire

    for repertoire in /srv/projets /srv/projets/externe /srv/maquettes /srv/clients; do
        if [ "$(stat -c '%U:%G %a' "$repertoire" 2>/dev/null)" != "root:root 770" ]; then
            mauvais="${mauvais} ${repertoire}"
        fi
    done

    if [ -z "$mauvais" ]; then
        ok "C2" "répertoires /srv en root:root 770"
    else
        ko "C2" "propriétaire ou mode différent de root:root 770 :${mauvais}"
    fi
}

# ---------------------------------------------------------------------------
# C3 : sudo
# ---------------------------------------------------------------------------

# test_C3_admins_sudo : les membres du groupe admins (ahmed et ismail) ont
# tous les droits sudo. LC_ALL=C force les messages de sudo en anglais.
test_C3_admins_sudo() {
    local sans_droit=""
    local login

    for login in ahmed ismail; do
        if ! LC_ALL=C sudo -l -U "$login" 2>/dev/null | grep -qF "(ALL : ALL) ALL"; then
            sans_droit="${sans_droit} ${login}"
        fi
    done

    if [ -z "$sans_droit" ]; then
        ok "C3" "ahmed et ismail ont tous les droits sudo"
    else
        ko "C3" "pas de droits sudo complets pour :${sans_droit}"
    fi
}

# test_C3_support_restreint : le compte support a une seule règle sudo, et
# c'est exactement le lancement de analyse_logs.sh en root, sans mot de passe.
test_C3_support_restreint() {
    local regles
    local nombre

    # Les règles sont les lignes qui commencent par des espaces puis "(".
    # sed retire les espaces du début pour comparer la ligne entière.
    regles="$(LC_ALL=C sudo -l -U support 2>/dev/null | grep -E '^ +\(' | sed 's/^ *//')"
    nombre="$(echo "$regles" | grep -c .)"

    if [ "$nombre" -eq 1 ] && [ "$regles" = "(root) NOPASSWD: /usr/local/sbin/analyse_logs.sh" ]; then
        ok "C3" "support ne peut lancer que analyse_logs.sh"
    else
        ko "C3" "règles sudo de support inattendues (${nombre}) : ${regles}"
    fi
}

# test_C3_aucun_autre_sudo : personne d'autre que les admins (et la règle
# limitée de support) n'a de droit sudo :
#   - le groupe sudo de Debian est vide et n'est le groupe principal de personne ;
#   - tous les autres comptes de comptes.csv sont refusés par sudo ;
#   - /etc/sudoers.d ne contient que nos deux fichiers (et le README de Debian).
test_C3_aucun_autre_sudo() {
    local problemes=""
    local membres_sudo
    local gid_sudo
    local principaux_sudo
    local autres_fichiers=""
    local logins_a_refuser
    local fichier
    local nom
    local login

    membres_sudo="$(getent group sudo | cut -d: -f4)"
    if [ -n "$membres_sudo" ]; then
        problemes="${problemes} membres du groupe sudo : ${membres_sudo} ;"
    fi

    gid_sudo="$(getent group sudo | cut -d: -f3)"
    principaux_sudo="$(awk -F: -v gid="$gid_sudo" '$4 == gid { print $1 }' /etc/passwd | tr '\n' ' ')"
    if [ -n "$principaux_sudo" ]; then
        problemes="${problemes} groupe principal sudo : ${principaux_sudo} ;"
    fi

    # Colonne 3 = groupe principal. On saute les admins et support.
    logins_a_refuser="$(awk -F';' 'NR > 1 && $1 != "" && $3 != "admins" && $3 != "support" { print $1 }' "$FICHIER_COMPTES")"
    for login in $logins_a_refuser; do
        if ! LC_ALL=C sudo -l -U "$login" 2>&1 | grep -q "not allowed to run sudo"; then
            problemes="${problemes} ${login} a un droit sudo ;"
        fi
    done

    for fichier in /etc/sudoers.d/*; do
        nom="$(basename "$fichier")"
        case "$nom" in
            10-admins|20-support|README) ;;
            *) autres_fichiers="${autres_fichiers} ${nom}" ;;
        esac
    done
    if [ -n "$autres_fichiers" ]; then
        problemes="${problemes} fichiers inattendus dans /etc/sudoers.d : ${autres_fichiers}"
    fi

    if [ -z "$problemes" ]; then
        ok "C3" "aucun droit sudo en dehors de admins et de la règle de support"
    else
        ko "C3" "${problemes}"
    fi
}

# inscriptible_par_non_root <chemin> : renvoie 0 si le groupe OU les autres
# ont le droit d'écrire sur le chemin. stat -c %A donne par exemple
# "-rwxr-xr-x" : le 6e caractère est le droit w du groupe, le 9e celui des autres.
inscriptible_par_non_root() {
    local droits

    droits="$(stat -c '%A' "$1")"
    if [ "${droits:5:1}" = "w" ] || [ "${droits:8:1}" = "w" ]; then
        return 0
    fi
    return 1
}

# test_C3_chemin_sudo_protege : la règle sudo de support vise un chemin précis.
# Si quelqu'un d'autre que root pouvait modifier ce script, ou renommer l'un
# de ses dossiers parents, il ferait exécuter ce qu'il veut en root. On exige
# donc :
#   - /usr/local/sbin/analyse_logs.sh est un vrai fichier (pas un lien),
#     appartient à root:root et n'est inscriptible ni par le groupe ni par les autres ;
#   - les dossiers /, /usr, /usr/local et /usr/local/sbin appartiennent à root
#     et ne sont inscriptibles ni par le groupe ni par les autres.
# Sur Debian, /usr/local et ses sous-dossiers sont parfois en root:staff 2775 :
# installer.sh retire donc l'écriture de groupe, plutôt que de compter sur le
# fait que le groupe staff soit vide.
test_C3_chemin_sudo_protege() {
    local script="/usr/local/sbin/analyse_logs.sh"
    local problemes=""
    local dossier

    if [ ! -f "$script" ] || [ -L "$script" ]; then
        ko "C3" "chemin sudo : ${script} absent ou lien symbolique"
        return
    fi

    if [ "$(stat -c '%U:%G' "$script")" != "root:root" ]; then
        problemes="${problemes} ${script} appartient à $(stat -c '%U:%G' "$script") ;"
    fi
    if inscriptible_par_non_root "$script"; then
        problemes="${problemes} ${script} inscriptible par le groupe ou les autres ;"
    fi

    for dossier in / /usr /usr/local /usr/local/sbin; do
        if [ "$(stat -c '%U' "$dossier")" != "root" ]; then
            problemes="${problemes} ${dossier} n'appartient pas à root ;"
        fi
        if inscriptible_par_non_root "$dossier"; then
            problemes="${problemes} ${dossier} inscriptible par le groupe ou les autres ;"
        fi
    done

    if [ -z "$problemes" ]; then
        ok "C3" "chemin de la règle sudo protégé (script et dossiers parents à root seul)"
    else
        ko "C3" "chemin de la règle sudo :${problemes}"
    fi
}

# ---------------------------------------------------------------------------
# C4 : root verrouillé, homes privés
# ---------------------------------------------------------------------------

# test_C4_root_verrouille : le mot de passe de root est verrouillé (état L).
test_C4_root_verrouille() {
    local etat
    etat="$(passwd -S root | awk '{ print $2 }')"

    if [ "$etat" = "L" ]; then
        ok "C4" "le compte root est verrouillé"
    else
        ko "C4" "état du compte root : ${etat} (attendu L)"
    fi
}

# test_C4_homes_prives : aucun /home/* n'est ouvert au groupe ni aux autres :
# le mode doit finir par 00 (700). cut -c2-3 garde les 2e et 3e chiffres du mode.
test_C4_homes_prives() {
    local ouverts=""
    local home
    local mode

    for home in /home/*; do
        if [ ! -d "$home" ]; then
            continue
        fi
        mode="$(stat -c '%a' "$home")"
        if [ "$(echo "$mode" | cut -c2-3)" != "00" ]; then
            ouverts="${ouverts} ${home}(${mode})"
        fi
    done

    if [ -z "$ouverts" ]; then
        ok "C4" "tous les homes sont fermés au groupe et aux autres (700)"
    else
        ko "C4" "homes accessibles au groupe ou aux autres :${ouverts}"
    fi
}

# ---------------------------------------------------------------------------
# S1 à S5 : accès SSH
# ---------------------------------------------------------------------------

# valeur_sshd <mot-clé> : affiche la valeur réellement appliquée par sshd pour
# ce mot-clé. "sshd -T" affiche la configuration finale (tous les fichiers
# lus, la première valeur trouvée gagne), avec les mots-clés en minuscules.
# Lire cette sortie est plus fiable que lire le fichier de config.
valeur_sshd() {
    sshd -T 2>/dev/null | awk -v cle="$1" '$1 == cle { print $2 }'
}

# test_S1_cle_seule : on ne se connecte que par clé (ni mot de passe, ni
# questions-réponses au clavier).
test_S1_cle_seule() {
    local mot_de_passe
    local clavier
    local cle

    mot_de_passe="$(valeur_sshd passwordauthentication)"
    clavier="$(valeur_sshd kbdinteractiveauthentication)"
    cle="$(valeur_sshd pubkeyauthentication)"

    if [ "$mot_de_passe" = "no" ] && [ "$clavier" = "no" ] && [ "$cle" = "yes" ]; then
        ok "S1" "SSH : clé publique seule (mot de passe et clavier désactivés)"
    else
        ko "S1" "SSH : passwordauthentication=${mot_de_passe} kbdinteractiveauthentication=${clavier} pubkeyauthentication=${cle}"
    fi
}

# test_S2_root_interdit : root ne peut pas se connecter en SSH.
test_S2_root_interdit() {
    local valeur
    valeur="$(valeur_sshd permitrootlogin)"

    if [ "$valeur" = "no" ]; then
        ok "S2" "SSH : connexion de root interdite"
    else
        ko "S2" "SSH : permitrootlogin=${valeur} (attendu no)"
    fi
}

# test_S3_allowgroups : seul le groupe acces_ssh a le droit de se connecter.
# "sshd -T" écrit UNE ligne par groupe : avec deux groupes autorisés on
# aurait deux lignes "allowgroups ...". L'ensemble des lignes allowgroups doit
# donc être exactement la ligne "allowgroups acces_ssh". Aucune ligne
# allowusers ne doit exister : un utilisateur nommé là passerait au travers
# du filtre par groupe.
test_S3_allowgroups() {
    local lignes_groupes
    local lignes_utilisateurs

    lignes_groupes="$(sshd -T 2>/dev/null | grep '^allowgroups ')"
    lignes_utilisateurs="$(sshd -T 2>/dev/null | grep '^allowusers ')"

    if [ "$lignes_groupes" != "allowgroups acces_ssh" ]; then
        ko "S3" "SSH : lignes allowgroups = $(echo "$lignes_groupes" | tr '\n' ';') (attendu exactement allowgroups acces_ssh)"
    elif [ -n "$lignes_utilisateurs" ]; then
        ko "S3" "SSH : allowusers est défini (${lignes_utilisateurs}), il contourne le filtre par groupe"
    else
        ok "S3" "SSH : réservé au groupe acces_ssh (aucun allowusers)"
    fi
}

# secondes_du_delai <valeur> : convertit "session=10m" ou "session=600" en
# secondes (sshd -T affiche la durée telle qu'elle est écrite dans la config).
# Affiche rien si la forme n'est pas reconnue (le test sera alors KO).
secondes_du_delai() {
    local duree="${1#session=}"

    case "$duree" in
        *m) duree="${duree%m}"; [[ "$duree" =~ ^[0-9]+$ ]] && echo $((duree * 60)) ;;
        *s) duree="${duree%s}"; [[ "$duree" =~ ^[0-9]+$ ]] && echo "$duree" ;;
        *)  [[ "$duree" =~ ^[0-9]+$ ]] && echo "$duree" ;;
    esac
}

# test_S4_essais_et_inactivite : au plus 4 essais par connexion, et deux
# réglages d'inactivité qui coupent en 900 s (15 minutes) au plus :
#   - ChannelTimeout coupe une session sans trafic (vraie inactivité) ;
#   - ClientAlive détecte une connexion morte : sshd envoie un message toutes
#     les "clientaliveinterval" s et coupe quand clientalivecountmax messages
#     de plus sont restés sans réponse, soit intervalle x (nombre + 1).
test_S4_essais_et_inactivite() {
    local essais
    local intervalle
    local nombre
    local delai_session
    local delai_mort
    local delai_inactif

    essais="$(valeur_sshd maxauthtries)"
    intervalle="$(valeur_sshd clientaliveinterval)"
    nombre="$(valeur_sshd clientalivecountmax)"
    delai_session="$(valeur_sshd channeltimeout)"
    delai_inactif="$(secondes_du_delai "$delai_session")"

    # Chaque valeur doit être un nombre entier : [[ =~ ]] compare à une
    # expression régulière (^[0-9]+$ = que des chiffres, au moins un).
    # Une valeur vide ou illisible donne un KO au lieu d'une erreur de calcul.
    if ! [[ "$essais" =~ ^[0-9]+$ ]]; then
        ko "S4" "SSH : maxauthtries illisible (${essais})"
        return
    fi
    if ! [[ "$intervalle" =~ ^[0-9]+$ ]]; then
        ko "S4" "SSH : clientaliveinterval illisible (${intervalle})"
        return
    fi
    if ! [[ "$nombre" =~ ^[0-9]+$ ]]; then
        ko "S4" "SSH : clientalivecountmax illisible (${nombre})"
        return
    fi
    if ! [[ "$delai_inactif" =~ ^[0-9]+$ ]]; then
        ko "S4" "SSH : channeltimeout absent ou illisible (${delai_session})"
        return
    fi

    delai_mort=$((intervalle * (nombre + 1)))
    if [ "$essais" -le 4 ] && [ "$intervalle" -gt 0 ] && [ "$delai_mort" -le 900 ] && [ "$delai_inactif" -gt 0 ] && [ "$delai_inactif" -le 900 ]; then
        ok "S4" "SSH : ${essais} essais au plus, session inactive coupée après ${delai_inactif} s, connexion morte après ${delai_mort} s"
    else
        ko "S4" "SSH : maxauthtries=${essais} (max 4), connexion morte après ${delai_mort} s et session inactive après ${delai_inactif} s (max 900, intervalle > 0)"
    fi
}

# test_S5_config_dans_drop_in : la configuration est dans un fichier de
# /etc/ssh/sshd_config.d/ (on ne touche pas à sshd_config) et sshd l'accepte.
test_S5_config_dans_drop_in() {
    if [ ! -f /etc/ssh/sshd_config.d/10-pixelia.conf ]; then
        ko "S5" "SSH : /etc/ssh/sshd_config.d/10-pixelia.conf absent"
    elif ! sshd -t 2>/dev/null; then
        ko "S5" "SSH : sshd -t refuse la configuration"
    else
        ok "S5" "SSH : config dans sshd_config.d/10-pixelia.conf, validée par sshd -t"
    fi
}

# ---------------------------------------------------------------------------
# J1 : fail2ban
# ---------------------------------------------------------------------------

# test_J1_fail2ban_actif : fail2ban tourne et sa prison sshd existe.
test_J1_fail2ban_actif() {
    if fail2ban-client status sshd >/dev/null 2>&1; then
        ok "J1" "fail2ban est actif et surveille la prison sshd"
    else
        ko "J1" "fail2ban-client status sshd échoue (fail2ban arrêté ou prison absente)"
    fi
}

# test_J1_valeurs_jail : valeurs lues auprès de fail2ban lui-même (pas dans le
# fichier) : 5 essais en 600 s (10 min) bannissent pendant 600 s (10 min).
test_J1_valeurs_jail() {
    local essais
    local duree_ban
    local fenetre

    essais="$(fail2ban-client get sshd maxretry 2>/dev/null)"
    duree_ban="$(fail2ban-client get sshd bantime 2>/dev/null)"
    fenetre="$(fail2ban-client get sshd findtime 2>/dev/null)"

    if [ "$essais" = "5" ] && [ "$duree_ban" = "600" ] && [ "$fenetre" = "600" ]; then
        ok "J1" "fail2ban : 5 essais en 600 s, ban de 600 s"
    else
        ko "J1" "fail2ban : maxretry=${essais} (attendu 5), bantime=${duree_ban} (600), findtime=${fenetre} (600)"
    fi
}

# ---------------------------------------------------------------------------
# J2 : pare-feu nftables
# ---------------------------------------------------------------------------

# test_J2_politique_drop : la chaîne d'entrée refuse tout ce qu'elle n'autorise pas.
test_J2_politique_drop() {
    if nft list chain inet filtre entree 2>/dev/null | grep -q 'policy drop'; then
        ok "J2" "pare-feu : chaîne entree en policy drop"
    else
        ko "J2" "pare-feu : la chaîne inet filtre entree n'existe pas ou n'est pas en policy drop"
    fi
}

# test_J2_ssh_et_etablies : SSH (port 22) est autorisé, ainsi que les
# réponses aux connexions déjà établies.
test_J2_ssh_et_etablies() {
    local regles
    regles="$(nft list chain inet filtre entree 2>/dev/null)"

    if echo "$regles" | grep -q 'tcp dport 22 accept' && echo "$regles" | grep -q 'ct state established,related accept'; then
        ok "J2" "pare-feu : SSH et connexions établies autorisés"
    else
        ko "J2" "pare-feu : règle tcp dport 22 accept ou ct state established,related accept absente"
    fi
}

# test_J2_au_demarrage : le pare-feu est rechargé à chaque démarrage.
test_J2_au_demarrage() {
    local etat
    etat="$(systemctl is-enabled nftables 2>/dev/null)"

    if [ "$etat" = "enabled" ]; then
        ok "J2" "pare-feu : nftables activé au démarrage"
    else
        ko "J2" "pare-feu : nftables n'est pas activé au démarrage (état : ${etat})"
    fi
}

# test_J2_regles_fail2ban_apres_rechargement : recharger nftables ne doit pas
# effacer les règles de fail2ban. Verifier ne recharge rien : il contrôle les
# deux conditions. La table f2b-table de fail2ban existe, et nftables.conf ne
# contient pas "flush ruleset" (qui effacerait toutes les tables au rechargement).
# Les lignes de commentaire (#) sont ignorées : le fichier explique pourquoi
# il n'a pas cette instruction.
test_J2_regles_fail2ban_apres_rechargement() {
    local fichier="/etc/nftables.conf"

    if ! nft list tables 2>/dev/null | grep -q 'f2b-table'; then
        ko "J2" "pare-feu : la table f2b-table de fail2ban est absente"
    elif [ ! -f "$fichier" ]; then
        ko "J2" "pare-feu : ${fichier} absent"
    elif grep -v '^[[:space:]]*#' "$fichier" | grep -q 'flush ruleset'; then
        ko "J2" "pare-feu : ${fichier} contient flush ruleset (un rechargement effacerait les règles de fail2ban)"
    else
        ok "J2" "pare-feu : f2b-table présente et nftables.conf sans flush ruleset"
    fi
}

# ---------------------------------------------------------------------------
# J3 : journal persistant
# ---------------------------------------------------------------------------

# test_J3_journal_persistant : la configuration finale de journald (tous les
# fichiers fusionnés) donne Storage=persistent, et /var/log/journal existe.
# On garde la dernière ligne Storage= : c'est celle qui gagne.
test_J3_journal_persistant() {
    local stockage

    stockage="$(systemd-analyze cat-config systemd/journald.conf 2>/dev/null | grep '^Storage=' | tail -n 1)"

    if [ "$stockage" != "Storage=persistent" ]; then
        ko "J3" "journal : réglage final ${stockage:-absent} (attendu Storage=persistent)"
    elif [ ! -d /var/log/journal ]; then
        ko "J3" "journal : /var/log/journal n'existe pas"
    else
        ok "J3" "journal : Storage=persistent et /var/log/journal présent"
    fi
}

# ---------------------------------------------------------------------------
# J4 : analyse des journaux SSH
# ---------------------------------------------------------------------------

# Script testé (la copie du dépôt, lancée avec bash) et journal d'exemple du TP.
SCRIPT_ANALYSE="${DOSSIER_DEPOT}/analyse_logs.sh"
JOURNAL_EXEMPLE="${DOSSIER_DEPOT}/tests/ssh_exemple_debian13.log"

# test_J4_seuil_depasse : avec un seuil de 5, le journal d'exemple doit donner
# le code 2 et une ligne ALERTE qui cite 203.0.113.45 (l'adresse qui attaque).
test_J4_seuil_depasse() {
    local sortie
    local code

    sortie="$(bash "$SCRIPT_ANALYSE" -f "$JOURNAL_EXEMPLE" -s 5 2>&1)"
    code=$?

    if [ "$code" -eq 2 ] && echo "$sortie" | grep -q 'ALERTE.*203\.0\.113\.45'; then
        ok "J4" "analyse : seuil 5 dépassé, code 2 et ALERTE sur 203.0.113.45"
    else
        ko "J4" "analyse : seuil 5, code ${code} (attendu 2) ou ligne ALERTE 203.0.113.45 absente"
    fi
}

# test_J4_sous_le_seuil : avec un seuil de 100 personne ne l'atteint, code 0.
test_J4_sous_le_seuil() {
    local sortie
    local code

    sortie="$(bash "$SCRIPT_ANALYSE" -f "$JOURNAL_EXEMPLE" -s 100 2>&1)"
    code=$?

    if [ "$code" -eq 0 ] && ! echo "$sortie" | grep -q 'ALERTE'; then
        ok "J4" "analyse : seuil 100 non atteint, code 0 et pas d'ALERTE"
    else
        ko "J4" "analyse : seuil 100, code ${code} (attendu 0) ou ALERTE affichée"
    fi
}

# test_J4_journal_vide : un journal vide n'est pas une erreur (code 0, pas d'ALERTE).
test_J4_journal_vide() {
    local sortie
    local code

    sortie="$(bash "$SCRIPT_ANALYSE" -f /dev/null 2>&1)"
    code=$?

    if [ "$code" -eq 0 ] && ! echo "$sortie" | grep -q 'ALERTE'; then
        ok "J4" "analyse : journal vide, code 0 et rien de compté"
    else
        ko "J4" "analyse : journal vide, code ${code} (attendu 0) ou ALERTE affichée"
    fi
}

# nombre_echecs_ip <adresse> <rapport> : lit dans la section "Échecs de
# connexion par adresse IP" du rapport le nombre affiché pour l'adresse (colonne 1,
# l'adresse est en colonne 2). N'affiche rien si l'adresse n'y figure pas.
nombre_echecs_ip() {
    echo "$2"         | sed -n '/^=== Échecs de connexion/,/^=== Comptes visés/p'         | awk -v adresse="$1" '$2 == adresse { print $1 }'
}

# test_J4_pas_de_double_compte : on compte par connexion (un numéro de
# processus sshd-session), pas par ligne. Une connexion en échec vaut autant
# de tentatives que de lignes "Failed password", ou 1 s'il n'y en a aucune.
# Une connexion qui a une ligne "Accepted" n'est pas en échec.
# Valeurs attendues, comptées à la main dans le journal d'exemple :
#   203.0.113.45 : 10 = 6 connexions sur des comptes inconnus (pid 1128, 1135,
#                  1142, 1149, 1156, 1163), chacune avec "Invalid user" ET
#                  "Failed password for invalid user" = 1 tentative chacune
#                  (6, pas 12) ; + pid 1170 : 3 lignes "Failed password" pour
#                  root = 3 tentatives dans UNE connexion ; + pid 1177 : 1.
#   198.51.100.23 : 3 = 3 connexions (pid 1184, 1191, 1198), 1 tentative chacune.
#   192.0.2.77 : 2 = 2 connexions (pid 1205, 1212) qui ne laissent que
#                "Connection closed by authenticating user root" (aucun
#                Failed password) : 1 tentative chacune.
#   192.168.56.1 : 1 = le seul pid en échec est 1114 (bob, "not allowed
#                because") ; les pid 1100 (alice, qui finit par "Accepted") et
#                1107 (etu, "Accepted") sont des connexions réussies.
test_J4_pas_de_double_compte() {
    local rapport
    local resultat=""
    local ligne
    local adresse
    local attendu
    local obtenu
    local tout_bon="oui"

    rapport="$(bash "$SCRIPT_ANALYSE" -f "$JOURNAL_EXEMPLE" 2>&1)"

    for ligne in "203.0.113.45 10" "198.51.100.23 3" "192.0.2.77 2" "192.168.56.1 1"; do
        adresse="${ligne% *}"
        attendu="${ligne#* }"
        obtenu="$(nombre_echecs_ip "$adresse" "$rapport")"
        resultat="${resultat} ${adresse}=${obtenu:-0}"
        if [ "$obtenu" != "$attendu" ]; then
            tout_bon="non"
        fi
    done

    if [ "$tout_bon" = "oui" ]; then
        ok "J4" "analyse : comptage par connexion exact (${resultat# })"
    else
        ko "J4" "analyse : comptage par connexion faux (${resultat# }), attendu 203.0.113.45=10 198.51.100.23=3 192.0.2.77=2 192.168.56.1=1"
    fi
}

# test_J4_ip_dans_nom : un nom d'utilisateur qui ressemble à une adresse IP ne
# doit pas fausser les comptes. L'adresse d'une connexion se lit seulement
# juste avant le mot "port" : ici 203.0.113.7, jamais 10.9.9.9 (le nom).
# Le fichier est créé dans un fichier temporaire, supprimé aussitôt.
test_J4_ip_dans_nom() {
    local temporaire
    local rapport

    temporaire="$(mktemp)"
    echo '2026-10-12T20:00:00+0200 debian sshd-session[4001]: Invalid user 10.9.9.9 from 203.0.113.7 port 4242' > "$temporaire"
    rapport="$(bash "$SCRIPT_ANALYSE" -f "$temporaire" 2>&1)"
    rm -f "$temporaire"

    if [ "$(nombre_echecs_ip 203.0.113.7 "$rapport")" = "1" ] && [ -z "$(nombre_echecs_ip 10.9.9.9 "$rapport")" ]; then
        ok "J4" "analyse : l'adresse vient de \"IP port N\" (203.0.113.7 compté, 10.9.9.9 ignoré)"
    else
        ko "J4" "analyse : 203.0.113.7 devrait compter 1 et 10.9.9.9 rien"
    fi
}

# test_J4_nom_piege : noms d'utilisateur hostiles. "Accepted" n'est pas une
# réussite, une adresse glissée dans le nom ne compte pas, et un PID réutilisé
# par une connexion réussie ne doit pas effacer l'échec précédent.
test_J4_nom_piege() {
    local temporaire
    local rapport
    local echecs
    local reussites

    temporaire="$(mktemp)"
    cat > "$temporaire" <<'JOURNAL'
2026-10-12T20:00:00+0200 debian sshd-session[5001]: Invalid user Accepted from 203.0.113.9 port 4001
2026-10-12T20:00:01+0200 debian sshd-session[5001]: Failed password for invalid user Accepted from 203.0.113.9 port 4001 ssh2
2026-10-12T20:00:02+0200 debian sshd-session[5001]: Connection closed by invalid user Accepted 203.0.113.9 port 4001 [preauth]
2026-10-12T20:00:03+0200 debian sshd-session[5002]: Invalid user x from 9.9.9.9 port 1 from 203.0.113.9 port 4002
2026-10-12T20:00:04+0200 debian sshd-session[5002]: Connection closed by invalid user x from 9.9.9.9 port 1 203.0.113.9 port 4002 [preauth]
2026-10-12T20:00:05+0200 debian sshd-session[5003]: Invalid user Accepted publickey for root from 6.6.6.6 port 1 from 203.0.113.9 port 4003
2026-10-12T20:00:06+0200 debian sshd-session[5003]: Connection closed by invalid user z 203.0.113.9 port 4003 [preauth]
2026-10-12T21:00:00+0200 debian sshd-session[5003]: Accepted publickey for alice from 192.168.56.1 port 5000 ssh2: ED25519 SHA256:abc
JOURNAL
    rapport="$(bash "$SCRIPT_ANALYSE" -f "$temporaire" 2>&1)"
    rm -f "$temporaire"

    echecs="$(echo "$rapport" | sed -n '/^=== Échecs de connexion/,/^=== Comptes visés/p')"
    reussites="$(echo "$rapport" | sed -n '/^=== Connexions réussies/,/^=== Bilan/p')"

    if [ "$(nombre_echecs_ip 203.0.113.9 "$rapport")" = "3" ] \
        && ! echo "$echecs" | grep -q -e '9\.9\.9\.9' -e '6\.6\.6\.6' \
        && ! echo "$reussites" | grep -q 'root.*6\.6\.6\.6'; then
        ok "J4" "analyse : noms piégés (203.0.113.9=3, 9.9.9.9 et 6.6.6.6 ignorés)"
    else
        ko "J4" "analyse : noms piégés mal traités (203.0.113.9 devrait compter 3, rien pour 9.9.9.9 et 6.6.6.6)"
    fi
}

# test_J4_proprietaire_root : le script installé appartient à root:root et
# seul root peut l'écrire (support le lance en root via sudo).
test_J4_proprietaire_root() {
    local script="/usr/local/sbin/analyse_logs.sh"

    if [ ! -f "$script" ]; then
        ko "J4" "analyse : ${script} absent"
    elif [ "$(stat -c '%U:%G' "$script")" != "root:root" ]; then
        ko "J4" "analyse : ${script} appartient à $(stat -c '%U:%G' "$script") (attendu root:root)"
    elif inscriptible_par_non_root "$script"; then
        ko "J4" "analyse : ${script} est inscriptible par le groupe ou les autres"
    else
        ok "J4" "analyse : ${script} appartient à root:root, écriture réservée à root"
    fi
}

# test_J4_sshd_session : Debian 13 écrit les connexions sous le nom
# sshd-session (et plus sshd). La section "Connexions réussies" doit donc
# lister alice et etu, qui n'apparaissent dans le journal d'exemple que par
# des lignes sshd-session. sed -n '/début/,/fin/p' garde la seule section voulue.
test_J4_sshd_session() {
    local section

    section="$(bash "$SCRIPT_ANALYSE" -f "$JOURNAL_EXEMPLE" 2>&1 | sed -n '/^=== Connexions réussies/,/^=== Bilan/p')"

    if echo "$section" | grep -qw 'alice' && echo "$section" | grep -qw 'etu'; then
        ok "J4" "analyse : connexions réussies de alice et etu lues (sshd-session)"
    else
        ko "J4" "analyse : alice et etu absents de la section Connexions réussies"
    fi
}

# test_J4_support_sans_f : la règle sudo de support accepte n'importe quel
# argument. Le script doit donc refuser -f pour support, sinon support
# ferait lire n'importe quel fichier à root. On lance exactement ce que
# ferait support : sudo -u support sudo -n ... -f /etc/shadow. La commande
# doit échouer, et aucune ligne de /etc/shadow ne doit apparaître.
test_J4_support_sans_f() {
    local sortie
    local code

    sortie="$(sudo -u support sudo -n /usr/local/sbin/analyse_logs.sh -f /etc/shadow 2>&1)"
    code=$?

    # grep -F : texte brut ; -x : ligne entière ; -f : les motifs sont les lignes de /etc/shadow.
    # On exige le code 1 ET le message de refus du script : un échec de sudo
    # (script absent, règle absente) ne doit pas passer pour un refus réussi.
    if [ "$code" -eq 0 ]; then
        ko "J4" "support a pu lancer analyse_logs.sh -f /etc/shadow (code 0)"
    elif echo "$sortie" | grep -qFxf /etc/shadow; then
        ko "J4" "support a obtenu des lignes de /etc/shadow"
    elif [ "$code" -ne 1 ] || ! echo "$sortie" | grep -q 'interdite'; then
        ko "J4" "support : -f échoue mais pas à cause du refus du script (code ${code}) : ${sortie}"
    else
        ok "J4" "support ne peut pas utiliser -f (refusé, code ${code}, rien de /etc/shadow)"
    fi
}

# ---------------------------------------------------------------------------
# D1 : mises à jour automatiques
# ---------------------------------------------------------------------------

# test_D1_mises_a_jour_auto : apt est réglé pour appliquer les mises à jour de
# sécurité chaque jour, et le service unattended-upgrades est actif.
test_D1_mises_a_jour_auto() {
    local etat

    etat="$(systemctl is-active unattended-upgrades 2>/dev/null)"

    if ! apt-config dump 2>/dev/null | grep -q 'APT::Periodic::Unattended-Upgrade "1"'; then
        ko "D1" "mises à jour : APT::Periodic::Unattended-Upgrade n'est pas à \"1\""
    elif [ "$etat" != "active" ]; then
        ko "D1" "mises à jour : service unattended-upgrades ${etat}"
    else
        ok "D1" "mises à jour automatiques activées (unattended-upgrades actif)"
    fi
}

# ---------------------------------------------------------------------------
# B1 à B4 : sauvegarde versionnée
# ---------------------------------------------------------------------------

# Disque de sauvegarde et dossier des versions.
POINT_SAUVEGARDE="/sauvegardes"
DOSSIER_VERSIONS="${POINT_SAUVEGARDE}/versions"

# lister_versions : affiche les noms de versions (format AAAA-MM-JJ_HHMMSS),
# de la plus ancienne à la plus récente, une par ligne. Ce format se trie dans
# l'ordre alphabétique comme dans l'ordre du temps.
lister_versions() {
    find "$DOSSIER_VERSIONS" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}$' | sort
}

# test_B1_disque_monte : /sauvegardes est monté depuis le disque d'étiquette
# "sauvegardes" (le second disque), et
# /etc/fstab le monte par UUID avec l'option nofail (la VM démarre même si le
# disque manque).
test_B1_disque_monte() {
    local source
    local uuid_reel
    local ligne_fstab

    source="$(findmnt -n -o SOURCE "$POINT_SAUVEGARDE" 2>/dev/null)"
    ligne_fstab="$(grep -E "^UUID=[^[:space:]]+[[:space:]]+${POINT_SAUVEGARDE}[[:space:]]" /etc/fstab)"

    # Le disque monté doit être celui qui porte l'étiquette "sauvegardes".
    if [ -z "$source" ] || [ "$source" != "$(blkid -L sauvegardes 2>/dev/null)" ]; then
        ko "B1" "disque : ${POINT_SAUVEGARDE} n'est pas monté depuis le disque d'étiquette sauvegardes (source : ${source:-aucune})"
        return
    fi

    if [ -z "$ligne_fstab" ]; then
        ko "B1" "disque : pas d'entrée UUID= pour ${POINT_SAUVEGARDE} dans /etc/fstab"
        return
    fi

    if ! echo "$ligne_fstab" | grep -q 'nofail'; then
        ko "B1" "disque : l'entrée fstab n'a pas l'option nofail"
        return
    fi

    # L'UUID écrit dans fstab doit être celui du disque monté.
    uuid_reel="$(blkid -s UUID -o value "$source")"
    if ! echo "$ligne_fstab" | grep -q "^UUID=${uuid_reel}[[:space:]]"; then
        ko "B1" "disque : l'UUID de fstab n'est pas celui de ${source} (${uuid_reel})"
        return
    fi

    ok "B1" "disque : ${source} monté sur ${POINT_SAUVEGARDE}, fstab par UUID avec nofail"
}

# test_B1_versions_datees : au moins deux versions datées (AAAA-MM-JJ_HHMMSS).
test_B1_versions_datees() {
    local nombre

    nombre="$(lister_versions | wc -l)"

    if [ "$nombre" -ge 2 ]; then
        ok "B1" "versions : ${nombre} versions datées dans ${DOSSIER_VERSIONS}"
    else
        ko "B1" "versions : ${nombre} version(s) datée(s) dans ${DOSSIER_VERSIONS} (2 attendues au moins)"
    fi
}

# test_B1_incrementale : un fichier inchangé de etc/ a le même numéro d'inode
# dans les deux dernières versions. C'est la preuve des liens durs de
# --link-dest : le fichier n'est stocké qu'une fois sur le disque.
test_B1_incrementale() {
    local avant_derniere
    local derniere
    local inode_avant
    local inode_dernier

    avant_derniere="$(lister_versions | tail -n 2 | head -n 1)"
    derniere="$(lister_versions | tail -n 1)"

    if [ -z "$avant_derniere" ] || [ "$avant_derniere" = "$derniere" ]; then
        ko "B1" "incrémentale : il faut deux versions pour comparer"
        return
    fi

    inode_avant="$(stat -c %i "${DOSSIER_VERSIONS}/${avant_derniere}/etc/hostname" 2>/dev/null)"
    inode_dernier="$(stat -c %i "${DOSSIER_VERSIONS}/${derniere}/etc/hostname" 2>/dev/null)"

    if [ -n "$inode_avant" ] && [ "$inode_avant" = "$inode_dernier" ]; then
        ok "B1" "incrémentale : etc/hostname a le même inode (${inode_dernier}) dans les deux dernières versions"
    else
        ko "B1" "incrémentale : etc/hostname a des inodes différents (${inode_avant:-absent} / ${inode_dernier:-absent})"
    fi
}

# test_B1_acl_conservees : la sauvegarde garde les ACL de /srv/projets
# (option -A de rsync) : la dernière version contient encore group:dev:rwx.
test_B1_acl_conservees() {
    local acl

    acl="$(getfacl -c "${DOSSIER_VERSIONS}/derniere/srv/projets" 2>/dev/null)"

    if echo "$acl" | grep -qx 'group:dev:rwx'; then
        ok "B1" "ACL conservées : srv/projets de la dernière version contient group:dev:rwx"
    else
        ko "B1" "ACL conservées : group:dev:rwx absent de derniere/srv/projets"
    fi
}

# test_B1_rotation : le script garde 7 versions (la valeur est écrite dans
# sauvegarde.sh), le script installé est celui du dépôt, et il n'y a pas plus
# de 7 versions sur le disque.
test_B1_rotation() {
    local nombre

    nombre="$(lister_versions | wc -l)"

    if ! grep -qx 'NB_VERSIONS_GARDEES=7' "${DOSSIER_DEPOT}/sauvegarde.sh" 2>/dev/null; then
        ko "B1" "rotation : NB_VERSIONS_GARDEES=7 absent de sauvegarde.sh"
    elif ! cmp -s "${DOSSIER_DEPOT}/sauvegarde.sh" /usr/local/sbin/sauvegarde.sh; then
        ko "B1" "rotation : /usr/local/sbin/sauvegarde.sh diffère de celui du dépôt"
    elif [ "$nombre" -gt 7 ]; then
        ko "B1" "rotation : ${nombre} versions sur le disque (7 au plus)"
    else
        ok "B1" "rotation : 7 versions gardées au plus (${nombre} présentes)"
    fi
}

# test_B2_timer_actif : le minuteur de sauvegarde est activé au démarrage et
# en cours d'attente.
test_B2_timer_actif() {
    local active
    local active_demarrage

    active_demarrage="$(systemctl is-enabled sauvegarde.timer 2>/dev/null)"
    active="$(systemctl is-active sauvegarde.timer 2>/dev/null)"

    if [ "$active_demarrage" = "enabled" ] && [ "$active" = "active" ]; then
        ok "B2" "planification : sauvegarde.timer activé (enabled) et actif"
    else
        ko "B2" "planification : sauvegarde.timer ${active_demarrage:-absent} / ${active:-absent} (enabled / active attendus)"
    fi
}

# test_B2_journalisee : le journal contient une ligne de fin de sauvegarde,
# écrite par "logger -t sauvegarde".
test_B2_journalisee() {
    if journalctl -t sauvegarde -o cat --no-pager 2>/dev/null | grep -q 'sauvegarde terminée'; then
        ok "B2" "journal : une ligne « sauvegarde terminée » dans journalctl -t sauvegarde"
    else
        ko "B2" "journal : aucune ligne « sauvegarde terminée » dans journalctl -t sauvegarde"
    fi
}

# test_B3_acces_admins : /sauvegardes est à root:root en 0700 : seuls root et
# les admins (par sudo) y accèdent ; un développeur ne peut pas le lire.
test_B3_acces_admins() {
    local droits
    local login

    droits="$(stat -c '%U:%G %a' "$POINT_SAUVEGARDE" 2>/dev/null)"

    if [ "$droits" != "root:root 700" ]; then
        ko "B3" "accès : ${POINT_SAUVEGARDE} est en ${droits:-absent} (root:root 700 attendu)"
        return
    fi

    # Un développeur, le compte support et un freelance ne doivent pas lire.
    for login in jdupont support kdurand; do
        if peut_lire "$login" "$POINT_SAUVEGARDE"; then
            ko "B3" "accès : ${login} peut lire ${POINT_SAUVEGARDE}"
            return
        fi
    done
    ok "B3" "accès : ${POINT_SAUVEGARDE} en root:root 700, jdupont, support et kdurand ne peuvent pas le lire"
}

# test_B4_restauration : on restaure srv/projets de la dernière version dans un
# dossier temporaire, puis on compare les ACL (getfacl) et le propriétaire,
# le groupe et le mode (stat) avec le vrai /srv/projets. Le dossier temporaire
# est supprimé aussitôt : le système n'est pas modifié.
test_B4_restauration() {
    local derniere
    local temporaire
    local acl_copie
    local acl_reelle
    local stat_copie
    local stat_reelle

    derniere="$(lister_versions | tail -n 1)"
    if [ -z "$derniere" ]; then
        ko "B4" "restauration : aucune version à restaurer"
        return
    fi

    temporaire="$(mktemp -d)"
    # cp -a garde propriétaires, modes et ACL, comme le ferait une vraie restauration.
    cp -a "${DOSSIER_VERSIONS}/${derniere}/srv/projets" "${temporaire}/projets" 2>/dev/null
    acl_copie="$(getfacl -c "${temporaire}/projets" 2>/dev/null)"
    stat_copie="$(stat -c '%U:%G %a' "${temporaire}/projets" 2>/dev/null)"
    rm -rf "$temporaire"

    acl_reelle="$(getfacl -c /srv/projets 2>/dev/null)"
    stat_reelle="$(stat -c '%U:%G %a' /srv/projets 2>/dev/null)"

    if [ -z "$acl_copie" ] || [ -z "$stat_copie" ]; then
        ko "B4" "restauration : srv/projets de la version ${derniere} n'a pas pu être restauré"
    elif [ "$acl_copie" != "$acl_reelle" ]; then
        ko "B4" "restauration : les ACL de srv/projets (version ${derniere}) diffèrent de /srv/projets"
    elif [ "$stat_copie" != "$stat_reelle" ]; then
        ko "B4" "restauration : propriétaire ou mode de srv/projets (${stat_copie}) diffère de /srv/projets (${stat_reelle})"
    else
        ok "B4" "restauration : srv/projets de la version ${derniere} restauré avec les mêmes ACL et ${stat_reelle}"
    fi
}

# test_B1_verrou : deux sauvegardes ne peuvent pas tourner en même temps. On
# tient le verrou /run/sauvegarde.lock pendant 3 secondes avec flock, puis on
# lance sauvegarde.sh : il doit refuser avec le message « déjà en cours ».
# Comme il s'arrête au verrou, il ne crée aucune version : rien de durable
# n'est modifié.
test_B1_verrou() {
    local sortie
    local code

    flock /run/sauvegarde.lock sleep 3 &
    sleep 1

    sortie="$(/usr/local/sbin/sauvegarde.sh 2>&1)"
    code=$?
    wait

    if [ "$code" -ne 0 ] && echo "$sortie" | grep -q 'déjà en cours'; then
        ok "B1" "verrou : une seconde sauvegarde est refusée pendant qu'une autre tourne"
    else
        ko "B1" "verrou : la seconde sauvegarde n'a pas été refusée (code ${code})"
    fi
}

# ---------------------------------------------------------------------------
# D2, D3 : écoutes réseau et fichiers sensibles
# ---------------------------------------------------------------------------

# test_D2_seul_ssh_ecoute : toute écoute hors boucle locale (127.0.0.0/8 et
# ::1) doit être sur le port 22. Seule exception : le client DHCP (UDP 68 en
# IPv4, UDP 546 en IPv6), qui écoute pour recevoir son bail d'adresse. Ce n'est
# pas un service offert aux autres machines. ss -tulnH liste les ports TCP et
# UDP en écoute, sans en-tête ; la 5e colonne est "adresse:port".
test_D2_seul_ssh_ecoute() {
    local proto
    local locale
    local adresse
    local port
    local intrus=""

    while read -r proto _ _ _ locale _; do
        port="${locale##*:}"
        adresse="${locale%:*}"
        # On enlève le nom de l'interface éventuel (fe80::1%ens33).
        adresse="${adresse%%\%*}"

        # Boucle locale : jamais joignable depuis le réseau.
        case "$adresse" in
            127.*|"[::1]") continue ;;
        esac

        # SSH : le seul service attendu.
        if [ "$port" = "22" ]; then
            continue
        fi

        # Client DHCP : UDP 68 (IPv4) et UDP 546 (IPv6).
        if [ "$proto" = "udp" ] && { [ "$port" = "68" ] || [ "$port" = "546" ]; }; then
            continue
        fi

        intrus="${intrus} ${proto}/${port}"
    done < <(ss -tulnH 2>/dev/null)

    if [ -z "$intrus" ]; then
        ok "D2" "écoutes réseau : seul SSH (22) écoute, hors client DHCP et boucle locale"
    else
        ko "D2" "écoutes réseau en trop :${intrus}"
    fi
}

# test_D3_aucun_fichier_modifiable_par_tous : un fichier modifiable par tous
# permettrait à n'importe quel compte de le remplacer. Seuls les répertoires
# avec sticky bit (comme /tmp) peuvent l'être. -xdev reste sur la partition
# racine : on ne descend pas dans /proc ni /sys. ! -type l ignore les liens
# symboliques (leurs droits sont toujours 777 et ne comptent pas).
test_D3_aucun_fichier_modifiable_par_tous() {
    local trouves

    trouves="$(find / -xdev ! -type l -perm -0002 \
        ! -path /tmp -prune ! -path '/tmp/*' \
        ! -path /var/tmp -prune ! -path '/var/tmp/*' \
        ! -path /dev/shm -prune ! -path '/dev/shm/*' \
        ! \( -type d -perm -1000 \) 2>/dev/null)"

    if [ -z "$trouves" ]; then
        ok "D3" "aucun fichier modifiable par tous (hors répertoires à sticky bit)"
    else
        ko "D3" "modifiable par tous : $(echo "$trouves" | head -5 | tr '\n' ' ')"
    fi
}

# test_D3_suid_connus : chaque fichier setuid doit figurer, avec son chemin
# exact, dans config/suid_attendus.txt. Un setuid inconnu est une porte
# d'élévation de privilèges possible. grep -Fxq compare ligne à ligne.
test_D3_suid_connus() {
    local liste="${DOSSIER_DEPOT}/config/suid_attendus.txt"
    local fichier
    local inconnus=""

    if [ ! -f "$liste" ]; then
        ko "D3" "setuid : ${liste} introuvable"
        return
    fi

    while IFS= read -r fichier; do
        if ! grep -v '^#' "$liste" | grep -Fxq -- "$fichier"; then
            inconnus="${inconnus} ${fichier}"
        fi
    done < <(find / -xdev -type f -perm -4000 2>/dev/null)

    if [ -z "$inconnus" ]; then
        ok "D3" "fichiers setuid : tous présents dans suid_attendus.txt"
    else
        ko "D3" "setuid inconnus :${inconnus}"
    fi
}

# ---------------------------------------------------------------------------
# Programme principal
# ---------------------------------------------------------------------------

# main : appelle une à une les fonctions de test, puis affiche le bilan.
# Les tests sont ajoutés ici au fur et à mesure, dans une liste explicite.
main() {
    test_C1_comptes_du_csv
    test_C1_sans_doublon
    test_C1_freelance_expire
    test_C2_projets
    test_C2_externe
    test_C2_maquettes
    test_C2_clients
    test_C2_acl_par_defaut
    test_C2_proprietaire_et_mode
    test_C3_admins_sudo
    test_C3_support_restreint
    test_C3_aucun_autre_sudo
    test_C3_chemin_sudo_protege
    test_C4_root_verrouille
    test_C4_homes_prives
    test_S1_cle_seule
    test_S2_root_interdit
    test_S3_allowgroups
    test_S4_essais_et_inactivite
    test_S5_config_dans_drop_in
    test_J1_fail2ban_actif
    test_J1_valeurs_jail
    test_J2_politique_drop
    test_J2_ssh_et_etablies
    test_J2_au_demarrage
    test_J2_regles_fail2ban_apres_rechargement
    test_J3_journal_persistant
    test_J4_seuil_depasse
    test_J4_sous_le_seuil
    test_J4_journal_vide
    test_J4_pas_de_double_compte
    test_J4_ip_dans_nom
    test_J4_proprietaire_root
    test_J4_sshd_session
    test_J4_support_sans_f
    test_J4_nom_piege
    test_D1_mises_a_jour_auto
    test_D2_seul_ssh_ecoute
    test_D3_aucun_fichier_modifiable_par_tous
    test_D3_suid_connus
    test_B1_disque_monte
    test_B1_versions_datees
    test_B1_incrementale
    test_B1_acl_conservees
    test_B1_rotation
    test_B1_verrou
    test_B2_timer_actif
    test_B2_journalisee
    test_B3_acces_admins
    test_B4_restauration

    echo "--- ${NB_OK} / ${NB_TESTS} tests réussis"

    if [ "$NB_OK" -ne "$NB_TESTS" ]; then
        return 1
    fi
    return 0
}

# Vérification des arguments : le script n'en attend aucun.
if [ "$#" -ne 0 ]; then
    echo "usage : sudo $0" >&2
    exit 2
fi

# Vérification de root : sudo -u et la lecture de /etc/shadow l'exigent.
if [ "$(id -u)" -ne 0 ]; then
    echo "ce script doit être lancé en root" >&2
    exit 2
fi

main
exit $?
