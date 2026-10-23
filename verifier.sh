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
    awk -F';' -v groupe="$1" 'NR > 1 && $3 == groupe { print $1 }' "$FICHIER_COMPTES"
}

# acces_reel <login> <répertoire> : affiche ce que l'utilisateur peut vraiment
# faire dans le répertoire : "rw" (lire et écrire), "r" (lire seulement),
# "x" (seulement le traverser) ou "-" (rien).
acces_reel() {
    local login="$1"
    local repertoire="$2"

    if peut_lire "$login" "$repertoire" && peut_ecrire "$login" "$repertoire"; then
        echo "rw"
    elif peut_lire "$login" "$repertoire"; then
        echo "r"
    elif sudo -u "$login" test -x "$repertoire" 2>/dev/null; then
        echo "x"
    else
        echo "-"
    fi
}

# verifier_repertoire <ID> <répertoire> <dev> <design> <commercial> <freelance> :
# compare l'accès réel de chaque membre de chaque groupe avec l'accès attendu
# (rw, r, x ou -) et affiche un seul [OK] ou [KO] pour le répertoire.
verifier_repertoire() {
    local id="$1"
    local repertoire="$2"
    local attendus=("$3" "$4" "$5" "$6")
    local groupes=(dev design commercial freelance)
    local ecarts=""
    local i
    local login
    local reel

    for i in 0 1 2 3; do
        for login in $(logins_du_groupe "${groupes[$i]}"); do
            reel="$(acces_reel "$login" "$repertoire")"
            if [ "$reel" != "${attendus[$i]}" ]; then
                ecarts="${ecarts} ${login}(attendu ${attendus[$i]}, obtenu ${reel})"
            fi
        done
    done

    if [ -z "$ecarts" ]; then
        ok "$id" "${repertoire} : droits conformes au tableau"
    else
        ko "$id" "${repertoire} :${ecarts}"
    fi
}

# ---------------------------------------------------------------------------
# C1 : comptes et groupes
# ---------------------------------------------------------------------------

# test_C1_comptes_du_csv : chaque login de comptes.csv existe et appartient à
# son groupe principal et à ses groupes secondaires.
test_C1_comptes_du_csv() {
    local manquants=""
    local login _nom principal secondaires
    local groupe

    if [ ! -f "$FICHIER_COMPTES" ]; then
        ko "C1" "comptes.csv introuvable"
        return
    fi

    # tail -n +2 saute la ligne d'en-tête ; tr retire d'éventuels retours chariot.
    while IFS=';' read -r login _nom principal secondaires || [ -n "$login" ]; do
        if ! id "$login" >/dev/null 2>&1; then
            manquants="${manquants} ${login}(compte absent)"
            continue
        fi
        if [ "$(id -gn "$login")" != "$principal" ]; then
            manquants="${manquants} ${login}(groupe principal différent de ${principal})"
        fi
        for groupe in ${secondaires//,/ }; do
            if ! id -nG "$login" | tr ' ' '\n' | grep -qx "$groupe"; then
                manquants="${manquants} ${login}(pas dans ${groupe})"
            fi
        done
    done < <(tail -n +2 "$FICHIER_COMPTES" | tr -d '\r')

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

# test_C2_acl_par_defaut : chaque répertoire a des ACL par défaut pour des
# groupes nommés, afin que les nouveaux fichiers gardent les bons droits.
test_C2_acl_par_defaut() {
    local sans_acl=""
    local repertoire

    for repertoire in /srv/projets /srv/projets/externe /srv/maquettes /srv/clients; do
        if ! getfacl -p "$repertoire" 2>/dev/null | grep -q "^default:group:[a-z]"; then
            sans_acl="${sans_acl} ${repertoire}"
        fi
    done

    if [ -z "$sans_acl" ]; then
        ok "C2" "ACL par défaut présentes sur les quatre répertoires"
    else
        ko "C2" "pas d'ACL par défaut sur :${sans_acl}"
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

# test_C3_support_restreint : le compte support ne peut lancer qu'une seule
# commande, analyse_logs.sh.
test_C3_support_restreint() {
    local regles
    local nombre

    # Les règles sont les lignes qui commencent par des espaces puis "(".
    regles="$(LC_ALL=C sudo -l -U support 2>/dev/null | grep -E '^ +\(')"
    nombre="$(echo "$regles" | grep -c .)"

    if [ "$nombre" -eq 1 ] && echo "$regles" | grep -qF "/usr/local/sbin/analyse_logs.sh"; then
        ok "C3" "support ne peut lancer que analyse_logs.sh"
    else
        ko "C3" "règles sudo de support inattendues (${nombre}) : ${regles}"
    fi
}

# test_C3_aucun_autre_sudo : le groupe sudo de Debian est vide et deux
# utilisateurs ordinaires n'ont aucun droit sudo.
test_C3_aucun_autre_sudo() {
    local membres_sudo
    local avec_droit=""
    local login

    membres_sudo="$(getent group sudo | cut -d: -f4)"
    for login in jdupont kdurand; do
        if ! LC_ALL=C sudo -l -U "$login" 2>&1 | grep -q "not allowed to run sudo"; then
            avec_droit="${avec_droit} ${login}"
        fi
    done

    if [ -z "$membres_sudo" ] && [ -z "$avec_droit" ]; then
        ok "C3" "groupe sudo vide, jdupont et kdurand sans droit sudo"
    else
        ko "C3" "membres du groupe sudo : '${membres_sudo}' ; avec droit sudo :${avec_droit}"
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

# test_C4_homes_prives : aucun /home/* n'est ouvert aux autres utilisateurs
# (dernier chiffre du mode égal à 0).
test_C4_homes_prives() {
    local ouverts=""
    local home
    local mode

    for home in /home/*; do
        mode="$(stat -c '%a' "$home")"
        if [ "${mode: -1}" != "0" ]; then
            ouverts="${ouverts} ${home}(${mode})"
        fi
    done

    if [ -z "$ouverts" ]; then
        ok "C4" "tous les homes sont fermés aux autres utilisateurs"
    else
        ko "C4" "homes accessibles aux autres :${ouverts}"
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
