"""Schéma, lecture et écriture de /etc/pra/pra.conf.

──────────────────────────────────────────────────────────────────────────────
POURQUOI CE MODULE EST LE PLUS SENSIBLE DE L'APPLICATION
──────────────────────────────────────────────────────────────────────────────
Le fichier produit ici est **`source`é par des scripts qui tournent en root**
(pra_nightly.sh, pra_restore_replica.sh…). Une valeur mal filtrée n'est donc pas
un simple bogue d'affichage : c'est une exécution de code arbitraire en root.

Exemple de ce qui doit être IMPOSSIBLE :

    PRA_WITNESSES="a"; rm -rf / #

D'où trois défenses superposées :

 1. Chaque réglage est TYPÉ (entier, choix fermé, nom d'hôte, chemin absolu…) et
    validé contre son type. Aucun champ n'accepte du texte libre sans contrôle.
 2. Un jeu de caractères interdits est appliqué à TOUTES les valeurs, quel que
    soit leur type : guillemets, dollar, accent grave, antislash, saut de ligne,
    point-virgule. Ce sont exactement les caractères qui permettent de sortir
    d'une chaîne entre guillemets doubles en shell.
 3. Le helper privilégié REVALIDE tout avant d'écrire. La webapp n'est jamais
    crue sur parole, conformément au modèle de Cert_yuno.

Le fichier emploie « : "${VAR:=valeur}" », qui n'affecte que les variables non
définies : une valeur passée à la main sur la ligne de commande reste donc
prioritaire sur le fichier.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

# ─────────────────────────────────────────────────────────────────────────────
# Filtrage de base — appliqué à toute valeur, sans exception
# ─────────────────────────────────────────────────────────────────────────────

# Caractères permettant de s'échapper d'une chaîne shell entre guillemets doubles.
INTERDITS = re.compile(r'["`$\\\n\r;|&<>()]')

RE_HOTE = re.compile(r"^[A-Za-z0-9]([A-Za-z0-9._-]{0,251}[A-Za-z0-9])?$")
RE_CHEMIN = re.compile(r"^/[A-Za-z0-9._/ -]{0,255}$")
RE_URL = re.compile(r"^https?://[A-Za-z0-9._-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$")
RE_JETON = re.compile(r"^[A-Za-z0-9._-]{1,128}$")
# Mot de passe d'application Nextcloud : lettres, chiffres et ponctuation sûre.
RE_SECRET = re.compile(r"^[A-Za-z0-9._~+/=@:-]{0,256}$")
# Motif de détection : on autorise la syntaxe des expressions régulières étendues
# MAIS aucun des caractères d'échappement shell (filtrés par INTERDITS au-dessus).
# « AAAA-MM-JJ » ou « AAAA-MM-JJ HH:MM ». Strict à dessein : une date
# approximative serait refusée par le script la nuit venue, donc la pause serait
# silencieusement inopérante — on préfère le dire au moment de la saisie.
RE_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}([ T]\d{2}:\d{2})?$")
RE_HEURE = re.compile(r"^([01]\d|2[0-3]):[0-5]\d$")
RE_MOTIF = re.compile(r"^[A-Za-z0-9._^\[\]{}*+?/:!@#%,'~=-]{1,2048}$")


class ValeurInvalide(ValueError):
    """Valeur refusée par la validation (message destiné à l'utilisateur)."""


# Noms lisibles des caractères invisibles : « contient un caractère interdit »
# sans dire lequel est indevinable quand le fautif ne se voit pas à l'écran.
_NOMS = {"\n": "un saut de ligne", "\r": "un retour chariot", "\t": "une tabulation"}


def _sans_caracteres_dangereux(valeur: str, libelle: str) -> str:
    trouve = INTERDITS.search(valeur)
    if trouve:
        c = trouve.group(0)
        raise ValeurInvalide(
            f"« {libelle} » contient un caractère interdit : {_NOMS.get(c, f'« {c} »')}. "
            "Les guillemets, $, `, \\, ;, |, &, <, >, ( ) et les sauts de ligne "
            "sont refusés : ce fichier est lu par des scripts privilégiés."
        )
    return valeur.strip()


# ─────────────────────────────────────────────────────────────────────────────
# Validateurs par type
# ─────────────────────────────────────────────────────────────────────────────


def v_entier(mini: int, maxi: int) -> Callable[[str, str], str]:
    def _v(valeur: str, libelle: str) -> str:
        valeur = valeur.strip()
        if not valeur:
            return ""
        if not re.fullmatch(r"-?\d{1,9}", valeur):
            raise ValeurInvalide(f"« {libelle} » doit être un nombre entier.")
        n = int(valeur)
        if not mini <= n <= maxi:
            raise ValeurInvalide(f"« {libelle} » doit être compris entre {mini} et {maxi}.")
        return str(n)

    return _v


def v_choix(options: tuple[str, ...]) -> Callable[[str, str], str]:
    def _v(valeur: str, libelle: str) -> str:
        valeur = valeur.strip()
        if valeur not in options:
            raise ValeurInvalide(
                f"« {libelle} » doit valoir l'une de ces valeurs : {', '.join(options)}."
            )
        return valeur

    return _v


def v_liste(motif: re.Pattern, quoi: str, maxi: int = 32) -> Callable[[str, str], str]:
    """Liste d'éléments séparés par des espaces ou des retours à la ligne."""

    def _v(valeur: str, libelle: str) -> str:
        # split() sans argument découpe sur TOUTE espace — espaces, tabulations,
        # \n ET \r. Ne remplacer que « \n » ne suffit pas : un navigateur envoie
        # les sauts de ligne d'un <textarea> en CRLF, le « \r » survit et se fait
        # refuser par INTERDITS — une liste collée sur plusieurs lignes est alors
        # rejetée sans motif visible.
        elements = valeur.split()
        _sans_caracteres_dangereux(" ".join(elements), libelle)
        if len(elements) > maxi:
            raise ValeurInvalide(f"« {libelle} » : {maxi} entrées au maximum.")
        for e in elements:
            if not motif.match(e):
                raise ValeurInvalide(f"« {libelle} » : « {e} » n'est pas {quoi}.")
        return " ".join(elements)

    return _v


def v_motif(motif: re.Pattern, quoi: str, obligatoire: bool = False):
    def _v(valeur: str, libelle: str) -> str:
        valeur = _sans_caracteres_dangereux(valeur, libelle)
        if not valeur:
            if obligatoire:
                raise ValeurInvalide(f"« {libelle} » est obligatoire.")
            return ""
        if not motif.match(valeur):
            raise ValeurInvalide(f"« {libelle} » n'est pas {quoi}.")
        return valeur

    return _v


def v_booleen(valeur: str, libelle: str) -> str:
    return "1" if valeur.strip() in ("1", "on", "true", "oui") else "0"


def v_parties_systeme(valeur: str, libelle: str) -> str:
    """Liste fermée : ces valeurs deviennent des arguments de « yunohost backup
    restore --system ». Un choix fermé, jamais du texte libre."""
    connues = {
        "conf_ldap",
        "data_home",
        "data_mail",
        "data_multimedia",
        "conf_manually_modified_files",
        "conf_ynh_settings",
        "conf_ynh_certs",
    }
    elements = [e for e in valeur.replace("\n", " ").split(" ") if e]
    for e in elements:
        if e not in connues:
            raise ValeurInvalide(f"« {libelle} » : partie système inconnue « {e} ».")
    return " ".join(elements)


# ─────────────────────────────────────────────────────────────────────────────
# Schéma des réglages
# ─────────────────────────────────────────────────────────────────────────────


# Un seul code, deux installations. Plutôt que deux applications à maintenir en
# parallèle — qui divergeraient — chaque réglage déclare les rôles auxquels il
# s'applique, et l'interface masque le reste.
#   « arche »      : le réplica. Réplication, contrôles, restauration.
#   « production » : le serveur source. Contenu de la sauvegarde.
ROLES = ("arche", "production")


@dataclass(frozen=True)
class Reglage:
    cle: str
    libelle: str
    groupe: str
    type: str  # texte | entier | choix | liste | secret | booleen | parties
    valider: Callable[[str, str], str]
    defaut: str = ""
    aide: str = ""
    options: tuple[str, ...] = field(default_factory=tuple)
    avance: bool = False  # replié dans l'interface
    roles: tuple[str, ...] = ROLES


# (titre, sous-titre, rôles concernés)
GROUPES = {
    "sauvegarde": ("Contenu de la sauvegarde",
                   "Ce qui est sauvegardé, et ce qui en est écarté.", ("production",)),
    "temoins": ("Témoins et quorum",
                "Machines interrogées avant toute réplication.", ("arche",)),
    # Les DEUX rôles : la production CRÉE les fichiers témoins, l'arche VÉRIFIE
    # leurs empreintes. Réserver la liste à l'arche rendait le bouton
    # « Déployer » inopérant côté production, et laissait les deux fichiers de
    # configuration diverger sans recours.
    "canaris": ("Canaris",
                "Fichiers témoins créés sur la production, vérifiés depuis l'arche.",
                ROLES),
    "anomalies": ("Contrôles d'archive",
                  "Analyse de l'archive avant le point de non-retour.", ("arche",)),
    "notification": ("Alertes",
                     "Notification Nextcloud Talk.", ROLES),
    "restauration": ("Ce qui est restauré",
                     "Sélection des applications et des piles. La liste vient de "
                     "l'inventaire de la veille.", ("arche",)),
    "retention": ("Rétention des archives",
                  "Combien de points de reprise sont conservés, et lesquels.", ROLES),
    "forge": ("Forge locale",
              "Publication nocturne des dépôts vers le Forgejo de l'arche.",
              ("arche",)),
}


def groupes_du_role(role: str) -> dict:
    return {k: (t_, s) for k, (t_, s, r) in GROUPES.items() if role in r}


def reglages_du_role(role: str) -> tuple:
    return tuple(r for r in REGLAGES if role in r.roles)

# Noms d'applications YunoHost : lettres, chiffres, tiret bas, et le suffixe
# « __2 » des instances multiples. Liste fermée par la FORME, faute de pouvoir
# l'être par le contenu — ces valeurs deviennent des arguments de
# « yunohost backup create ».
RE_APP = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")

REGLAGES: tuple[Reglage, ...] = (
    # ── Sauvegarde (production) ──────────────────────────────────────────────
    Reglage(
        "PRA_BACKUP_EXCLUDE", "Applications écartées", "sauvegarde", "apps",
        v_liste(RE_APP, "un nom d'application valide"), roles=("production",),
        aide="Applications à NE PAS sauvegarder. Utile pour celles qui n'ont "
             "aucune donnée propre (cyberchef, diagramsnet…) ou qui sont trop "
             "volumineuses pour l'arche. Attention : une application écartée ne "
             "pourra pas être restaurée — c'est un arbitrage, pas une "
             "optimisation.",
    ),
    Reglage(
        "PRA_BACKUP_SYSTEM", "Inclure les parties système", "sauvegarde", "booleen",
        v_booleen, defaut="1", roles=("production",),
        aide="Les parties système portent notamment « conf_ldap », donc les "
             "utilisateurs, groupes et permissions. Sans elles, l'arche ne "
             "pourrait jamais rattraper la dérive des comptes.",
    ),
    # ── Témoins ──────────────────────────────────────────────────────────────
    Reglage(
        "PRA_WITNESSES", "Machines témoins", "temoins", "liste",
        v_liste(RE_HOTE, "un nom d'hôte ou une adresse IP valide"),
        defaut="",
        aide="Une par ligne ou séparées par des espaces. La première doit être la "
             "source des sauvegardes : elle est bloquante à elle seule. Ajouter "
             "d'autres machines (commutateur, hyperviseur, baie) rend le quorum "
             "plus significatif.",
        roles=("arche",),
    ),
    Reglage(
        "PRA_QUORUM_MIN", "Témoins devant répondre", "temoins", "entier",
        v_entier(1, 32),
        aide="Laisser vide pour la majorité stricte. En dessous de ce seuil, "
             "l'arche suppose un incident large : elle ne réplique pas, ne "
             "restaure pas, et conserve son état. Une nuit perdue se rattrape ; "
             "une arche écrasée par une sauvegarde empoisonnée, non.",
        roles=("arche",),
    ),
    # ── Canaris ──────────────────────────────────────────────────────────────
    Reglage(
        "PRA_CANARY_PATHS", "Emplacements des canaris", "canaris", "liste",
        v_liste(RE_CHEMIN, "un chemin absolu valide"),
        aide="Chemins ABSOLUS sur la production. Volontairement sans valeur par "
             "défaut : ces emplacements ne doivent pas figurer dans le code, "
             "qu'un dépôt publierait — un attaquant y lirait la liste des "
             "fichiers à éviter. Ce sont des appâts : les "
             "rançongiciels ciblent par extension, donc garder des noms de "
             "documents ordinaires (.docx, .pdf, .xlsx). ÉVITER tout répertoire "
             "dont le contenu est géré par un autre processus : "
             "/home/yunohost.app/<app>/ (effacé par « yunohost app remove ») et "
             "ou un répertoire de journaux qui n'accepte qu'un nommage précis "
             "et supprime tout le reste, au prix d'une nuit de réplication. ET "
             "surtout : le fichier doit être LISIBLE par le compte que l'arche "
             "utilise en SSH. Le répertoire d'un autre utilisateur, protégé par "
             "une ACL, donnerait un canari signalé absent en permanence. Cette "
             "liste sert sur LES DEUX machines : la production y crée les "
             "fichiers, l'arche les vérifie. Gardez-les identiques, sinon un "
             "déploiement recréera un emplacement retiré de la surveillance.",
    ),
    Reglage(
        "PRA_CANARY_ABSENTS_MAX", "Absences tolérées", "canaris", "entier",
        v_entier(0, 10), defaut="1",
        aide="Un canari DISPARU est un signal faible : ménage, « rsync --delete », "
             "collègue. Un canari MODIFIÉ est concluant — c'est un chiffrement sur "
             "place, et il bloque toujours. Au-delà de ce seuil d'absences, la "
             "disparition devient groupée donc suspecte, et bloque aussi. À 0, "
             "toute absence bloque.",
        roles=("arche",),
    ),
    Reglage(
        "PRA_CANARY_MANIFEST", "Fichier manifeste", "canaris", "texte",
        v_motif(RE_CHEMIN, "un chemin absolu valide"),
        defaut="/etc/pra/canaries.list",
        aide="Empreintes de référence, générées par « Recalculer les empreintes ».",
        avance=True,
        roles=("arche",),
    ),
    # ── Anomalies ────────────────────────────────────────────────────────────
    Reglage(
        "PRA_ANOMALY_ACTION", "En cas d'anomalie", "anomalies", "choix",
        v_choix(("bloquer", "alerter")),
        defaut="bloquer", options=("bloquer", "alerter"),
        aide="« bloquer » refuse la restauration et laisse l'arche intacte — "
             "c'est le réglage sûr. « alerter » restaure malgré tout en "
             "signalant : à ne garder que le temps de lever un faux positif.",
        roles=("arche",),
    ),
    Reglage(
        "PRA_SIZE_DELTA_MAX", "Écart de taille toléré (%)", "anomalies", "entier",
        v_entier(5, 95), defaut="40",
        aide="Écart maximal entre la taille de l'archive du jour et la MÉDIANE "
             "des précédentes. Le chiffrement étant incompressible, la taille "
             "change franchement. Trop bas, vous bloquerez sur la croissance "
             "normale des données.",
        roles=("arche",),
    ),
    Reglage(
        "PRA_RANSOM_PATTERN", "Motif de détection", "anomalies", "texte",
        v_motif(RE_MOTIF, "une expression régulière acceptable"),
        aide="Expression régulière étendue appliquée à la liste des fichiers de "
             "l'archive. Laisser vide pour le motif par défaut, volontairement "
             "restrictif : « README.txt » seul est banal et bloquerait chaque "
             "nuit. Ne cibler que les verbes de rançon et les extensions de "
             "chiffrement.",
        avance=True,
        roles=("arche",),
    ),
    # ── Notification ─────────────────────────────────────────────────────────
    Reglage(
        "NC_TALK_URL", "Adresse Nextcloud", "notification", "texte",
        v_motif(RE_URL, "une adresse http(s) valide"),
        aide="Racine du Nextcloud de PRODUCTION, sans barre finale. "
             "Ex. https://nextcloud.exemple.org",
    ),
    Reglage(
        "NC_TALK_ROOM", "Jeton de la conversation", "notification", "texte",
        v_motif(RE_JETON, "un jeton valide"),
        aide="Partie finale de l'URL Talk : .../call/<jeton>",
    ),
    Reglage(
        "NC_TALK_IP", "Adresse IP du Nextcloud", "notification", "texte",
        v_motif(RE_HOTE, "une adresse IP ou un nom d'hôte valide"),
        aide="INDISPENSABLE depuis l'arche : les domaines de production y ont été "
             "restaurés comme domaines YunoHost, donc dnsmasq les résout vers "
             "l'arche elle-même. Sans cette adresse, l'alerte partirait vers son "
             "propre nginx. Le nom est conservé pour le SNI, la vérification TLS "
             "reste donc entière. Vide = on reprend la première machine témoin.",
        roles=("arche",),
    ),
    Reglage(
        "NC_TALK_CACERT", "Autorité de certification", "notification", "texte",
        v_motif(RE_CHEMIN, "un chemin absolu valide"),
        aide="Chemin vers la CA interne si le certificat du Nextcloud de "
             "production n'est pas reconnu. L'authentification étant en Basic, "
             "le mot de passe circule dans chaque requête : la vérification TLS "
             "n'est pas une formalité.",
        avance=True,
    ),
    Reglage(
        "NC_TALK_INSECURE", "Ne pas vérifier le certificat", "notification", "booleen",
        v_booleen, defaut="0",
        aide="À n'activer qu'en dernier recours et temporairement : sans "
             "vérification, un intercepteur récupère le mot de passe "
             "d'application. Chaque envoi le signale alors dans le journal.",
        avance=True,
    ),
    Reglage(
        "NC_TALK_SECRET", "Secret du bot", "notification", "secret",
        v_motif(RE_SECRET, "un secret acceptable"),
        aide="Secret du bot Talk, obtenu à sa déclaration côté Nextcloud. Il ne "
             "circule JAMAIS sur le réseau : il sert uniquement à signer chaque "
             "message (HMAC-SHA256 de random + message). Ce n'est donc pas un "
             "mot de passe de compte, et il reste révocable seul.",
    ),
    # ── Rétention et restauration ────────────────────────────────────────────
    Reglage(
        "PRA_RESTORE_APPS", "Applications restaurées", "restauration", "cibles",
        v_liste(RE_APP, "un nom d'application valide"), roles=("arche",),
        aide="Vide = toutes celles de la table. La liste proposée vient de "
             "l'inventaire de la DERNIÈRE exécution, donc de la veille : une "
             "application choisie ici et absente de l'archive du jour sera "
             "écartée avec une trace, sans faire échouer la nuit.",
    ),
    Reglage(
        "PRA_PAUSE_JUSQUA", "Suspendre jusqu'au", "restauration", "datetime",
        v_motif(RE_DATE, "une date au format AAAA-MM-JJ ou AAAA-MM-JJ HH:MM"),
        aide="Suspend la réplication ET l'extinction automatique jusqu'à cette "
             "date — pour travailler la nuit sans que l'arche restaure "
             "par-dessus ni s'éteigne sous vos pieds. Laisser vide en "
             "fonctionnement normal. La reprise est AUTOMATIQUE à l'échéance : "
             "c'est délibéré, une suspension sans limite serait un dispositif "
             "éteint qui se croit actif. Elle est plafonnée à 7 jours, et chaque "
             "nuit suspendue envoie une alerte pour qu'on ne l'oublie pas.",
        roles=("arche",),
    ),
    Reglage(
        # Posée à la main dans le fichier, hors schéma, cette clé est effacée
        # par la première réécriture de la webapp : le réveil de mise au point
        # disparaît « tout seul ». Déclarée ici, elle est visible, validée, et
        # survit aux enregistrements.
        "PRA_WAKE_AT", "Heure du réveil", "restauration", "texte",
        v_motif(RE_HEURE, "une heure au format HH:MM"), roles=("arche",),
        # Le libellé disait « Réveil supplémentaire » et l'aide « arme EN PLUS » :
        # c'était FAUX, et dangereusement — le réglage REMPLACE le réveil de
        # 02:00, il ne s'y ajoute pas (« au lieu de », dit le journal). Une aide
        # qui promet un réveil de secours inexistant ferait croire la
        # réplication garantie alors qu'elle ne se déclencherait plus.
        aide="Vide = réveil standard à 02:00 le lendemain, celui de la "
             "réplication. Une heure (par exemple 09:00) REMPLACE ce réveil par "
             "un réveil de jour — pour une période de mise au point : la machine "
             "se rallume à cette heure, ne restaure rien (hors de la fenêtre "
             "1h-5h) et ne se rendort pas d'elle-même. Tant que ce champ est "
             "rempli, il n'y a plus de réveil nocturne : à vider dès le débogage "
             "fini. Chaque nuit le signale en RÉVEIL NON STANDARD.",
    ),
    Reglage(
        "PRA_FORGEJO_TOKEN", "Jeton de la forge", "forge", "secret",
        v_motif(RE_JETON, "un jeton acceptable"), roles=("arche",),
        aide="Jeton d'accès Forgejo utilisé par la synchronisation nocturne des "
             "dépôts. Sans lui, la publication est simplement sautée, avec une "
             "trace « PRA_FORGEJO_TOKEN absent » dans le journal forgejo.",
    ),
    Reglage(
        "PRA_DOCKER_STACKS", "Piles Docker restaurées", "restauration", "piles",
        v_liste(RE_APP, "un nom de pile valide"), roles=("arche",),
        aide="Vide = toutes les piles présentes dans l'instantané. Même décalage "
             "de 24 h, et même garde-fou : une pile absente de l'instantané du "
             "jour est ignorée.",
    ),
    Reglage(
        "PRA_GFS_JOURS", "Jours conservés", "retention", "entier",
        v_entier(1, 60), defaut="4",
        aide="Nombre de jours DISPONIBLES conservés, non de jours calendaires : "
             "si la réplication a manqué trois nuits, ce sont bien les quatre "
             "derniers jours présents qui sont gardés.",
    ),
    Reglage(
        "PRA_GFS_LUNDIS", "Lundis conservés", "retention", "entier",
        v_entier(0, 52), defaut="2",
    ),
    Reglage(
        "PRA_GFS_MOIS", "Premiers du mois conservés", "retention", "entier",
        v_entier(0, 60), defaut="3",
        aide="« Premier » au sens de la plus ancienne archive du mois, et non du "
             "1er du calendrier — qui n'a pas toujours de sauvegarde. C'est "
             "cette strate qui protège d'un chiffrement lent passé inaperçu "
             "plus longtemps que la profondeur quotidienne.",
    ),
    Reglage(
        "PRA_PURGE_APPLIQUER", "Supprimer réellement les archives", "retention",
        "booleen", v_booleen, defaut="1",
        aide="Décoché, la purge se contente d'un compte rendu dans le journal. "
             "Laissé ainsi, le disque finit par se remplir et la restauration "
             "casse : le défaut est donc à coché. Décocher pour revenir au "
             "constat sans suppression.",
    ),
    Reglage(
        "PRA_KEEP_MIN", "Archives conservées au minimum", "retention", "entier",
        v_entier(1, 60), defaut="5",
        aide="Conservées quel que soit leur âge. C'est le plancher qui garantit "
             "qu'il reste toujours de quoi restaurer, même après une série "
             "d'échecs.",
    ),
    Reglage(
        "PRA_RETENTION_DAYS", "Âge maximal des archives (jours)", "retention", "entier",
        v_entier(1, 3650), defaut="30",
        aide="Appliqué seulement au-delà du plancher ci-dessus.",
    ),
    Reglage(
        "PRA_SYSTEM_PARTS", "Parties système restaurées", "restauration", "parties",
        v_parties_systeme,
        options=(
            "conf_ldap", "data_home", "data_mail", "data_multimedia",
            "conf_manually_modified_files", "conf_ynh_settings", "conf_ynh_certs",
        ),
        defaut="conf_ldap",
        aide="« conf_ldap » est coché par défaut : il apporte les utilisateurs, "
             "les groupes et les permissions. Sans lui l'arche dérive en silence — "
             "un mot de passe changé sur la production ne fonctionne pas ici, et "
             "on ne le découvre qu'en crise. Vérifié sur une archive réelle : elle "
             "ne contient AUCUNE URL, la restauration ne peut donc pas défaire "
             "l'adaptation des adresses. « conf_ynh_settings » et "
             "« conf_ynh_certs » portent en revanche la configuration des domaines "
             "de production et entrent en conflit avec ceux de l'arche.",
        roles=("arche",),
    ),
    Reglage(
        "PRA_LOG_KEEP_DAYS", "Rétention des journaux NAT (jours)", "retention", "entier",
        v_entier(1, 3650), defaut="90",
        roles=("arche",),
    ),
    Reglage(
        "PRA_LOG_PURGE", "Purger réellement les journaux NAT", "retention", "booleen",
        v_booleen, defaut="0",
        aide="Décoché, la purge se contente d'un compte rendu. Une suppression mal "
             "ciblée sur des journaux d'investigation est irréversible : ne cocher "
             "qu'après avoir vérifié la liste dans le journal.",
        avance=True,
        roles=("arche",),
    ),
)

PAR_CLE = {r.cle: r for r in REGLAGES}
SECRETS = {r.cle for r in REGLAGES if r.type == "secret"}

ENTETE = """# Configuration du plan de reprise d'activité — NE PAS MODIFIER À LA MAIN.
# Écrit par la webapp Arche, lu par les scripts du PRA.
#
# L'idiome « : "${VAR:=valeur}" » n'affecte QUE les variables non définies :
# une valeur passée sur la ligne de commande reste prioritaire sur ce fichier.
"""


def lire(chemin: Path) -> dict[str, str]:
    """Relit le fichier. Tolérant : une ligne incomprise est ignorée, jamais fatale."""
    valeurs: dict[str, str] = {}
    if not chemin.exists():
        return valeurs
    motif = re.compile(r'^\s*:?\s*"?\$\{([A-Z_][A-Z0-9_]*):?=(.*?)\}"?\s*$')
    # « CLE="valeur" » mais aussi « CLE=valeur » : c'est la forme qu'écrit une
    # main pressée, un « echo … | tee -a » en pleine nuit. Sans elle, une clé du
    # schéma posée ainsi n'est NI relue comme valeur NI préservée hors schéma —
    # donc effacée au premier enregistrement.
    simple = re.compile(r'^\s*([A-Z_][A-Z0-9_]*)=(?:"(.*)"|([^"\s#]\S*))\s*$')
    for ligne in chemin.read_text(encoding="utf-8", errors="replace").splitlines():
        if not ligne.strip() or ligne.lstrip().startswith("#"):
            continue
        m = motif.match(ligne)
        if m:
            cle, valeur = m.group(1), m.group(2)
        else:
            m = simple.match(ligne)
            if not m:
                continue
            cle = m.group(1)
            valeur = m.group(2) if m.group(2) is not None else m.group(3)
        if cle in PAR_CLE:
            valeurs[cle] = valeur
    return valeurs


def lire_hors_schema(chemin: Path) -> list[str]:
    """Lignes du fichier qui ne relèvent pas du schéma — conservées telles quelles.

    Le fichier est régénéré en entier à chaque enregistrement : tout ce que le
    schéma ignore disparaît SILENCIEUSEMENT. Un jeton posé à la main s'efface
    ainsi, et ne se signale que par plusieurs nuits d'« absent » avant qu'on
    comprenne. Les clés connues sont déclarées au schéma, mais la
    prochaine ligne posée à la main subirait le même sort : on préserve donc la
    CLASSE, pas seulement les deux victimes connues.

    On ne préserve pas n'importe quoi : uniquement des AFFECTATIONS lisibles
    (« CLE=valeur », « CLE="valeur" » ou l'idiome « : "${CLE:=valeur}" ») dont
    la clé est inconnue du schéma. Ces lignes étaient déjà dans un fichier que
    seul root écrit : les reconduire n'ouvre aucun droit nouveau — la webapp,
    elle, reste incapable d'en créer (le helper refuse toute clé inconnue).
    """
    if not chemin.exists():
        return []
    idiome = re.compile(r'^\s*:?\s*"?\$\{([A-Z_][A-Z0-9_]*):?=(.*?)\}"?\s*$')
    simple = re.compile(r'^\s*([A-Z_][A-Z0-9_]*)=("?)(.*)\2\s*$')
    lignes: list[str] = []
    for ligne in chemin.read_text(encoding="utf-8", errors="replace").splitlines():
        if not ligne.strip() or ligne.lstrip().startswith("#"):
            continue
        m = idiome.match(ligne) or simple.match(ligne)
        if m and m.group(1) not in PAR_CLE:
            lignes.append(ligne.rstrip())
    return lignes


def valider(brut: dict[str, str]) -> dict[str, str]:
    """Valide l'ensemble et renvoie les valeurs propres. Lève ValeurInvalide."""
    propre: dict[str, str] = {}
    for reglage in REGLAGES:
        # Réglage ABSENT de la soumission : on ne l'écrit PAS.
        #
        # Y injecter la valeur par défaut du schéma fait accumuler à chaque
        # machine des réglages appartenant à l'autre rôle, figés à la date
        # d'écriture, invisibles dans son interface et impossibles à corriger :
        # une liste de canaris périmée, des témoins qui ne sont plus les bons.
        # Les scripts ont leurs propres valeurs par défaut ; un réglage
        # absent du fichier est donc sans conséquence, et bien plus honnête qu'un
        # réglage périmé.
        if reglage.cle not in brut:
            continue
        else:
            valeur = brut[reglage.cle]
            if not isinstance(valeur, str):
                raise ValeurInvalide(f"« {reglage.libelle} » : valeur inattendue.")
            if not valeur.strip() and reglage.type == "choix":
                valeur = reglage.defaut
        propre[reglage.cle] = reglage.valider(valeur, reglage.libelle)
    _coherence(propre)
    return propre


def _coherence(v: dict[str, str]) -> None:
    """Contrôles qui portent sur plusieurs réglages à la fois."""
    # Les témoins ne concernent QUE l'arche : c'est elle qui les interroge avant
    # de répliquer. Le rôle « production » n'expose donc pas ce champ — la clé
    # est alors absente, et l'exiger revient à interdire toute modification sur
    # la production : impossible d'y corriger la liste des canaris, bloqué par
    # « au moins une machine témoin est nécessaire ».
    #
    # On n'exige donc les témoins que lorsque le réglage fait partie du
    # périmètre — présent dans la configuration existante ou dans la soumission.
    # Sur l'arche, le champ est toujours affiché : la garantie y est intacte.
    if "PRA_WITNESSES" not in v:
        temoins: list[str] = []
    else:
        temoins = [t for t in v.get("PRA_WITNESSES", "").split(" ") if t]
        if not temoins:
            raise ValeurInvalide(
                "Au moins une machine témoin est nécessaire : la première est la "
                "source des sauvegardes."
            )
    quorum = v.get("PRA_QUORUM_MIN", "")
    if quorum and temoins and int(quorum) > len(temoins):
        raise ValeurInvalide(
            f"Le quorum ({quorum}) dépasse le nombre de témoins ({len(temoins)}) : "
            "la réplication ne pourrait jamais avoir lieu."
        )
    # Les trois vont ensemble : une adresse sans jeton ni secret ne produirait
    # aucune alerte, et le croire configuré est pire que de le savoir absent.
    talk = [bool(v.get(c)) for c in ("NC_TALK_URL", "NC_TALK_ROOM", "NC_TALK_SECRET")]
    if any(talk) and not all(talk):
        raise ValeurInvalide(
            "Les alertes Talk exigent les trois valeurs ensemble : adresse "
            "Nextcloud, jeton de la conversation et secret du bot. En l'état, "
            "aucune alerte ne partirait."
        )


def rendre(valeurs: dict[str, str], hors_schema: list[str] | None = None) -> str:
    """Produit le contenu du fichier.

    La valeur est écrite telle quelle : elle se trouve déjà à l'intérieur d'une
    chaîne entre guillemets doubles (« : "${VAR:=valeur}" »), où les espaces sont
    sans effet. Seuls comptent les caractères permettant d'en sortir — et un
    ULTIME contrôle les rejette ici, juste avant l'écriture. On ne s'appuie
    jamais sur un seul rempart pour un fichier lu en root.
    """
    lignes = [ENTETE]
    # GROUPES porte (titre, sous-titre, rôles) : on ne dépaquette PAS un nombre
    # fixe de valeurs ici, sinon ajouter un champ au schéma casse l'écriture de
    # la configuration.
    for groupe, infos in GROUPES.items():
        titre = infos[0]
        lignes.append(f"\n# ─── {titre} " + "─" * max(0, 60 - len(titre)))
        for reglage in REGLAGES:
            if reglage.groupe != groupe:
                continue
            valeur = valeurs.get(reglage.cle, "")
            if valeur == "":
                lignes.append(f'# : "${{{reglage.cle}:=}}"   # non défini')
                continue
            if INTERDITS.search(valeur):
                raise ValeurInvalide(
                    f"Écriture refusée : « {reglage.libelle} » contient un "
                    "caractère interdit. Ce fichier est lu par des scripts root."
                )
            lignes.append(f': "${{{reglage.cle}:={valeur}}}"')
    # Les lignes hors schéma relues par lire_hors_schema() : sans cette section,
    # chaque enregistrement détruisait ce que le schéma ne connaît pas — voir
    # le récit complet sur lire_hors_schema().
    if hors_schema:
        lignes.append("\n# ─── Hors schéma " + "─" * 44)
        lignes.append("# Lignes posées à la main, inconnues du schéma : reconduites telles quelles.")
        lignes.extend(hors_schema)
    return "\n".join(lignes) + "\n"
