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
# shellcheck disable=SC2317  # pas encore appelée : réservée aux tests des tâches suivantes
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
test_S3_allowgroups() {
    # La ligne entière doit être exactement "allowgroups acces_ssh" : un
    # second groupe sur la ligne ferait échouer le test (grep -x = ligne entière).
    if sshd -T 2>/dev/null | grep -qx 'allowgroups acces_ssh'; then
        ok "S3" "SSH : réservé au groupe acces_ssh"
    else
        ko "S3" "SSH : allowgroups=$(valeur_sshd allowgroups) (attendu exactement acces_ssh)"
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
    test_C4_root_verrouille
    test_C4_homes_prives
    test_S1_cle_seule
    test_S2_root_interdit
    test_S3_allowgroups
    test_S4_essais_et_inactivite
    test_S5_config_dans_drop_in

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
