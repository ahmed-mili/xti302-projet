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
        sudo -u "$login" test -r "$chemin" && sudo -u "$login" test -x "$chemin"
    else
        sudo -u "$login" test -r "$chemin"
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
# Programme principal
# ---------------------------------------------------------------------------

# main : appelle une à une les fonctions de test, puis affiche le bilan.
# Les tests sont ajoutés ici au fur et à mesure, dans une liste explicite.
main() {
    # (aucun test pour l'instant)

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
