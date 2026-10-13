#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Remplit le dépôt de secours en images d'amorçage et en outils.
#
# Le point qu'on rate souvent : une image « netinst » NE S'INSTALLE PAS SANS
# INTERNET. Elle ne contient que l'amorceur et va chercher les paquets en ligne.
# Le jour où l'on reconstruit sans réseau — c'est-à-dire le seul jour où ce dépôt
# sert — elle est inutile. D'où le DVD-1 systématiquement à côté : lui contient
# de quoi installer un système complet hors ligne.
#
# TOUT EST VÉRIFIÉ. Une image d'installation empoisonnée dans le dépôt de secours
# annulerait l'ensemble du dispositif : on reconstruirait la production à partir
# d'un support compromis, en croyant repartir sain. Chaque fichier est donc
# contrôlé contre la somme SHA-256 publiée par le projet, récupérée en HTTPS.
#
# Les téléchargements sont REPRENABLES : relancer le script après une coupure
# reprend où il en était, et saute ce qui est déjà vérifié.
#
# Usage :
#   pra_depot_isos.sh              télécharge ce qui manque
#   pra_depot_isos.sh --verifier   compare au publié, SANS rien télécharger
#   pra_depot_isos.sh --nettoyer   retire les versions périmées
#   pra_depot_isos.sh --liste      montre les sources
#   pra_depot_isos.sh --manifeste  régénère seulement le manifeste
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

DEPOT="${PRA_DEPOT:-/home/yunohost.app/filebrowser}"
ISO="$DEPOT/iso"
OUTILS="$DEPOT/outils"
# Les manuels ne vivent PAS dans le dépôt de fichiers mais dans /var/www.
#
# Le dépôt est en 750, propriété de son propre compte : nginx ne peut pas même
# le traverser. Servis depuis là, les manuels ne s'ouvriraient qu'à travers
# l'interface du dépôt — qui rend les fichiers un par un, sans faire fonctionner
# les liens entre pages. Un miroir dont les liens sont morts ne vaut rien.
#
# Ici, ils sont servis comme un vrai site sur le port de secours, sans
# authentification : ce sont des documentations publiques, et le jour où elles
# servent, exiger un portail serait absurde.
DOC="${PRA_DOC:-/var/www/arche-manuels}"
# Le répertoire que lit kiwix-serve, et donc celui où les .zim doivent ARRIVER.
# Voir le commentaire de « traiter() » : les déposer ailleurs puis les déplacer à
# la main faisait retélécharger 21 Go à chaque passage.
KIWIX="${PRA_KIWIX:-/home/yunohost.app/kiwix}"
MANIFESTE="$DEPOT/MANIFESTE-DEPOT.txt"
LIMITE="${PRA_DEPOT_LIMITE:-}"          # ex. « 5M » pour brider ; vide = plein débit

bleu() { printf '\033[1;34m::\033[0m %s\n' "$*"; }
ok()   { printf '   \033[32m✓\033[0m %s\n' "$*"; }
mal()  { printf '   \033[31m✗\033[0m %s\n' "$*" >&2; }
info() { printf '     %s\n' "$*"; }

# ── Le catalogue ────────────────────────────────────────────────────────────
# Format : catégorie | sous-dossier | URL de base | fichier de sommes | motif
#
# Le MOTIF sert à retrouver le nom de fichier courant DANS le fichier de sommes,
# plutôt que de figer un numéro de version qui périmerait le script à chaque
# publication. C'est ce qui lui permet de suivre les versions tout seul.
CATALOGUE=(
  # ── Debian 13, la version courante ────────────────────────────────────────
  "Debian 13 amd64 netinst|debian|https://cdimage.debian.org/debian-cd/current/amd64/iso-cd|SHA256SUMS|^debian-1[0-9.]*-amd64-netinst\.iso$"
  "Debian 13 amd64 DVD-1|debian|https://cdimage.debian.org/debian-cd/current/amd64/iso-dvd|SHA256SUMS|^debian-1[0-9.]*-amd64-DVD-1\.iso$"
  "Debian 13 arm64 netinst|debian|https://cdimage.debian.org/debian-cd/current/arm64/iso-cd|SHA256SUMS|^debian-1[0-9.]*-arm64-netinst\.iso$"
  "Debian 13 arm64 DVD-1|debian|https://cdimage.debian.org/debian-cd/current/arm64/iso-dvd|SHA256SUMS|^debian-1[0-9.]*-arm64-DVD-1\.iso$"

  # ── Debian 12 : LA VERSION EN SERVICE sur la production. Reconstruire à
  #    l'identique compte plus que reconstruire au dernier goût du jour.
  "Debian 12 amd64 netinst|debian|https://cdimage.debian.org/cdimage/archive/12.11.0/amd64/iso-cd|SHA256SUMS|^debian-12[0-9.]*-amd64-netinst\.iso$"
  "Debian 12 amd64 DVD-1|debian|https://cdimage.debian.org/cdimage/archive/12.11.0/amd64/iso-dvd|SHA256SUMS|^debian-12[0-9.]*-amd64-DVD-1\.iso$"
  "Debian 12 arm64 netinst|debian|https://cdimage.debian.org/cdimage/archive/12.11.0/arm64/iso-cd|SHA256SUMS|^debian-12[0-9.]*-arm64-netinst\.iso$"
  # L'arche est un Raspberry Pi : le DVD-1 arm64 est ce qui permet de la
  # reconstruire HORS LIGNE, la netinst allant chercher ses paquets en ligne.
  "Debian 12 arm64 DVD-1|debian|https://cdimage.debian.org/cdimage/archive/12.11.0/arm64/iso-dvd|SHA256SUMS|^debian-12[0-9.]*-arm64-DVD-1\.iso$"

  # ── Ubuntu ────────────────────────────────────────────────────────────────
  "Ubuntu Server 24.04 amd64|ubuntu|https://releases.ubuntu.com/24.04|SHA256SUMS|^ubuntu-24\.04[0-9.]*-live-server-amd64\.iso$"
  "Ubuntu Desktop 24.04 amd64|ubuntu|https://releases.ubuntu.com/24.04|SHA256SUMS|^ubuntu-24\.04[0-9.]*-desktop-amd64\.iso$"
  # Les images ARM d'Ubuntu ne sont PAS sur releases.ubuntu.com, qui ne publie
  # que l'amd64 : elles vivent sur cdimage.ubuntu.com. Chercher au premier
  # endroit et conclure qu'elles n'existent pas est l'erreur facile.
  "Ubuntu Server 24.04 arm64|ubuntu|https://cdimage.ubuntu.com/releases/24.04/release|SHA256SUMS|^ubuntu-24\.04[0-9.]*-live-server-arm64\.iso$"
  "Ubuntu Desktop 24.04 arm64|ubuntu|https://cdimage.ubuntu.com/releases/24.04/release|SHA256SUMS|^ubuntu-24\.04[0-9.]*-desktop-arm64\.iso$"

  # ── Le monde Red Hat. RHEL exige un compte : Rocky et Alma en sont les
  #    substituts binaires exacts, et se téléchargent librement.
  "Rocky Linux 9 DVD|redhat|https://download.rockylinux.org/pub/rocky/9/isos/x86_64|CHECKSUM|^Rocky-9\.[0-9]+-x86_64-dvd\.iso$"
  "AlmaLinux 9 DVD|redhat|https://repo.almalinux.org/almalinux/9/isos/x86_64|CHECKSUM|^AlmaLinux-9\.[0-9]+-x86_64-dvd\.iso$"

  # ── Secours ───────────────────────────────────────────────────────────────
  "SystemRescue|secours|https://fastly-cdn.system-rescue.org/releases/13.01|systemrescue-13.01-amd64.iso.sha256|^systemrescue-1[0-9.]*-amd64\.iso$"

  # ── Investigation ─────────────────────────────────────────────────────────
  # KALI : L'INSTALLER, PAS LE LIVE — et ce n'est pas un choix, c'est un constat.
  #
  # « cdimage.kali.org/current » ne sert aucune ISO : ses images sont sous
  # « kali-images/current ». Mais surtout, l'image LIVE y rend
  # 404 sur les trois hôtes testés (cdimage, kali.download, base-images), en HEAD
  # comme en GET partiel — alors que le listing du répertoire l'annonce et que
  # SHA256SUMS en donne l'empreinte. Incohérence côté projet : la liste est
  # produite depuis un manifeste, pas depuis les fichiers réellement servis.
  # Seules les images « installer » se téléchargent.
  #
  # Le manque est couvert : CAINE et SystemRescue assurent le démarrage en lecture
  # seule sur disque, qui est l'usage d'investigation. Ce qu'on perd est l'outillage
  # de Kali en live — à reprendre par torrent, noté dans le LISEZ-MOI du dossier.
  "Kali Linux Installer|forensic|https://cdimage.kali.org/kali-images/current|SHA256SUMS|^kali-linux-[0-9.]*-installer-amd64\.iso$"

  # ── Documentation hors ligne (Kiwix) ──────────────────────────────────────
  # « INDEX » : le fichier de sommes n'existe pas globalement, mais chaque
  # archive a son « .sha256 ». On lit donc l'index du répertoire, on prend la
  # plus récente — les noms sont datés AAAA-MM, l'ordre alphabétique suffit — et
  # on vérifie contre son propre fichier de sommes.
  #
  # L'ordre ci-dessous est celui de l'utilité réelle : ce qu'on interroge à 3 h
  # du matin devant un message d'erreur, ce ne sont pas les encyclopédies, ce
  # sont les sites de questions-réponses d'administration système.
  "Kiwix — Server Fault|kiwix|https://download.kiwix.org/zim/stack_exchange|INDEX|serverfault\.com_en_all_[0-9-]+\.zim"
  "Kiwix — Super User|kiwix|https://download.kiwix.org/zim/stack_exchange|INDEX|superuser\.com_en_all_[0-9-]+\.zim"
  "Kiwix — Unix & Linux|kiwix|https://download.kiwix.org/zim/stack_exchange|INDEX|unix\.stackexchange\.com_en_all_[0-9-]+\.zim"
  "Kiwix — Ask Ubuntu|kiwix|https://download.kiwix.org/zim/stack_exchange|INDEX|askubuntu\.com_en_all_[0-9-]+\.zim"
  "Kiwix — Sécurité|kiwix|https://download.kiwix.org/zim/stack_exchange|INDEX|security\.stackexchange\.com_en_all_[0-9-]+\.zim"
  "Kiwix — wiki Arch Linux|kiwix|https://download.kiwix.org/zim/other|INDEX|archlinux_en_all_maxi_[0-9-]+\.zim"
  "Kiwix — Wikipédia fr|kiwix|https://download.kiwix.org/zim/wikipedia|INDEX|wikipedia_fr_all_nopic_[0-9-]+\.zim"

  # ── Fedora ────────────────────────────────────────────────────────────────
  # « {VER} » est remplacé par la version la plus récente publiée : sans cela le
  # script continuerait à récupérer une version figée pendant des années, sans
  # que rien ne le signale.
  "Fedora Workstation|fedora|https://download.fedoraproject.org/pub/fedora/linux/releases/{VER}/Workstation/x86_64/iso|~Fedora-Workstation-[0-9.-]+-x86_64-CHECKSUM|^Fedora-Workstation-Live-.*\.iso$"
  "Fedora Server|fedora|https://download.fedoraproject.org/pub/fedora/linux/releases/{VER}/Server/x86_64/iso|~Fedora-Server-[0-9.-]+-x86_64-CHECKSUM|^Fedora-Server-dvd-.*\.iso$"

  # ── NixOS — pour le projet Bureautix-Univ ────────────────────────────────
  "NixOS minimal|nixos|SIDECAR|https://channels.nixos.org/nixos-26.05/latest-nixos-minimal-x86_64-linux.iso|nixos-minimal-x86_64.iso"
  # Canal 26.05 et non 25.05 : c'est la version stable courante, et l'ancienne
  # ne publie plus d'image de bureau du tout.
  #
  # « graphical » et non « plasma6 » : NixOS a renommé son image de bureau, et
  # l'ancien nom rend 404 — y compris sa somme, d'où l'échec « somme absente »
  # qui laissait croire à un problème de vérification alors que l'image entière
  # avait disparu. Le répertoire de publication ne contient plus que
  # « nixos-graphical » et « nixos-minimal ».
  "NixOS bureau|nixos|SIDECAR|https://channels.nixos.org/nixos-26.05/latest-nixos-graphical-x86_64-linux.iso|nixos-graphical-x86_64.iso"

  # ── Raspberry Pi OS — pour reconstruire l'arche elle-même ────────────────
  "Raspberry Pi OS Lite|raspberrypi|SIDECAR|https://downloads.raspberrypi.com/raspios_lite_arm64_latest|raspios-lite-arm64.img.xz"
  "Raspberry Pi OS complet|raspberrypi|SIDECAR|https://downloads.raspberrypi.com/raspios_arm64_latest|raspios-arm64.img.xz"

  # ── Secours ───────────────────────────────────────────────────────────────
  "Clonezilla Live|secours|https://free.nchc.org.tw/clonezilla-live/stable|SHA256SUMS|^clonezilla-live-[0-9a-z.-]+-amd64\.iso$"

  # ── Investigation : CAINE. Aucune somme publiée à une URL stable, d'où
  #    INDEXNV. Le miroir d'Aix-la-Chapelle est celui que le projet met en
  #    avant, et son index est navigable — on y prend la version la plus haute.
  "CAINE|forensic|http://ftp.halifax.rwth-aachen.de/caine|INDEXNV|caine[0-9]+\.[0-9]+\.iso"

  # ── Outils. GitHub ne publie pas de somme exploitable : ces fichiers sont
  #    récupérés mais NON VÉRIFIÉS, et le manifeste le dit.
  "KeePassXC (Windows)|outils|GITHUB|keepassxreboot/keepassxc|^KeePassXC-[0-9.]+-Win64\.msi$"
  "KeePassXC (Linux x86_64)|outils|GITHUB|keepassxreboot/keepassxc|^KeePassXC-[0-9.]+-x86_64\.AppImage$"
  "balenaEtcher (Windows)|outils|GITHUB|balena-io/etcher|^balenaEtcher-[0-9.]+\.Setup\.exe$"
  # Graver une image sur clé. Rufus est Windows seulement : il faut donc un
  # équivalent pour Linux et macOS, sans quoi un poste sous l'un des deux ne
  # peut pas fabriquer la clé de secours.
  "Rufus (Windows)|outils|GITHUB|pbatard/rufus|^rufus-[0-9.]+\.exe$"
  # « imager-v2.0.10.exe » : le projet a changé le séparateur et ajouté le « v ».
  # Le motif est volontairement tolérant aux deux écritures — un motif trop
  # strict transforme une simple renomination amont en absence silencieuse.
  "Pi Imager (Windows)|outils|GITHUB|raspberrypi/rpi-imager|^imager[-_]v?[0-9.]+\.exe$"
  "Pi Imager (Linux x86_64)|outils|GITHUB|raspberrypi/rpi-imager|^Raspberry_Pi_Imager-v[0-9.]+-desktop-x86_64\.AppImage$"
  "Pi Imager (Linux ARM64)|outils|GITHUB|raspberrypi/rpi-imager|^Raspberry_Pi_Imager-v[0-9.]+-desktop-aarch64\.AppImage$"
  "Pi Imager (.deb amd64)|outils|GITHUB|raspberrypi/rpi-imager|^rpi-imager_[0-9.]+_amd64\.deb$"
  "Pi Imager (.deb arm64)|outils|GITHUB|raspberrypi/rpi-imager|^rpi-imager_[0-9.]+_arm64\.deb$"
  "Pi Imager (.deb amd64, console)|outils|GITHUB|raspberrypi/rpi-imager|^rpi-imager-cli_[0-9.]+_amd64\.deb$"
  "Pi Imager (.deb arm64, console)|outils|GITHUB|raspberrypi/rpi-imager|^rpi-imager-cli_[0-9.]+_arm64\.deb$"
  "balenaEtcher (Linux)|outils|GITHUB|balena-io/etcher|^balenaEtcher-linux-x64-[0-9.]+\.zip$"
  "balenaEtcher (macOS Intel)|outils|GITHUB|balena-io/etcher|^balenaEtcher-[0-9.]+-x64\.dmg$"
  "balenaEtcher (macOS ARM)|outils|GITHUB|balena-io/etcher|^balenaEtcher-[0-9.]+-arm64\.dmg$"
  # Ventoy : la version etait figee a 1.1.07 alors que le projet en est a 1.1.17.
  # Une URL codee en dur se perime en silence — on la decouvre desormais.
  # L'archive Linux contient les binaires de plusieurs architectures, dont
  # aarch64 : une seule archive couvre le parc x86 et ARM.
  "Ventoy (Linux)|outils|GITHUB|ventoy/Ventoy|^ventoy-[0-9.]+-linux\.tar\.gz$"
  "Ventoy (Windows)|outils|GITHUB|ventoy/Ventoy|^ventoy-[0-9.]+-windows\.zip$"
  "Ventoy (CD amorçable)|outils|GITHUB|ventoy/Ventoy|^ventoy-[0-9.]+-livecd\.iso$"

  # ── DFIR ORC — le collecteur d'artefacts de l'ANSSI ───────────────────────
  # Il ne s'installe pas : on le pose sur une machine Windows suspecte, il
  # collecte les artefacts d'investigation et rend une archive. C'est l'outil
  # français de référence pour figer un poste AVANT de le réparer — et réparer
  # sans avoir collecté détruit les traces qu'on cherchera ensuite.
  "DFIR ORC (collecteur)|forensic|GITHUB|DFIR-ORC/dfir-orc|^DFIR-ORC\.exe$"
  "DFIR ORC (FastFind)|forensic|GITHUB|DFIR-ORC/dfir-orc|^FastFind\.exe$"
  "DFIR ORC (binaires)|forensic|GITHUB|DFIR-ORC/dfir-orc|^DFIR-ORC-binaries\.zip$"

  # ── Binaires statiques de diagnostic ──────────────────────────────────────
  # SUR UNE MACHINE COMPROMISE, ON NE FAIT PAS CONFIANCE AUX BINAIRES LOCAUX.
  # Un « ls » modifié cache les fichiers de l'attaquant, un « ps » modifié cache
  # ses processus, un « netstat » modifié cache ses connexions. C'est la première
  # chose qu'un rootkit remplace, et on ne le voit pas.
  #
  # Ces exécutables sont liés statiquement : ils n'utilisent aucune bibliothèque
  # de la machine examinée, donc rien de ce qu'on y a pu substituer. Quelques
  # mégaoctets pour le geste de base de la réponse à incident.
)

# Fichiers isolés, sans fichier de sommes exploitable : somme figée, vérifiée à
# la main une fois. Le manifeste dit clairement lesquels sont dans ce cas.
DIRECTS=(
  # busybox.net publie des exécutables statiques officiels, mais sans somme :
  # ils sont récupérés NON VÉRIFIÉS, et le manifeste le dit.
  # L'arche est un Raspberry Pi et le parc a les deux architectures : chaque
  # binaire de diagnostic existe donc en x86_64 ET en aarch64.
  "busybox statique x86_64|statiques|https://raw.githubusercontent.com/ryanwoodsmall/static-binaries/master/x86_64/busybox"
  "busybox statique aarch64|statiques|https://raw.githubusercontent.com/ryanwoodsmall/static-binaries/master/aarch64/busybox"
  "curl statique x86_64|statiques|https://raw.githubusercontent.com/ryanwoodsmall/static-binaries/master/x86_64/curl"
  "curl statique aarch64|statiques|https://raw.githubusercontent.com/ryanwoodsmall/static-binaries/master/aarch64/curl"
  "socat statique x86_64|statiques|https://raw.githubusercontent.com/ryanwoodsmall/static-binaries/master/x86_64/socat"
  "socat statique aarch64|statiques|https://raw.githubusercontent.com/ryanwoodsmall/static-binaries/master/aarch64/socat"
  # YunoHost ne s'installe pas depuis une ISO mais depuis ce script, posé sur une
  # Debian nue. Le script seul ne suffit pas hors ligne — il va chercher des
  # paquets — mais il fait partie de ce qu'il faut avoir sous la main, et sa
  # présence rappelle que la vraie dépendance est le MIROIR APT (voir depot.md).
  "Script d'installation YunoHost|outils|https://install.yunohost.org/"
  # GParted et Hiren's : URL stables, sommes publiées seulement sur une page web.
  "GParted Live|secours|https://downloads.sourceforge.net/gparted/gparted-live-1.8.1-3-amd64.iso"
  "Hiren's BootCD PE|secours|https://www.hirensbootcd.org/files/HBCD_PE_x64.iso"

)

# ── Documentation des outils ────────────────────────────────────────────────
# Avoir l'outil sans savoir s'en servir ne sert à rien — et c'est exactement ce
# qui arrive le jour où sa documentation en ligne est inaccessible. On garde donc
# une copie navigable hors ligne des manuels, à côté des images.
#
# Format : libellé | sous-dossier | URL racine | plafond de taille
# Format : libellé | dossier | URL | plafond | catégorie | à quoi ça sert
#
# PARTIR DE LA RACINE DU SITE, pas d'une sous-page. « --no-parent » interdit de
# remonter : un miroir lancé sur « /manual/ » ne verra jamais « /lvm-guide-en/ »,
# et un miroir lancé sur « /page5/ » ne verra jamais « /page8/ » — c'est ainsi
# qu'on s'est retrouvé avec UNE page pour CAINE, dont le manuel est en page8.
#
# L'option existe pour ne pas aspirer tout un domaine depuis une page enfouie ;
# depuis la racine elle ne coûte rien, et le plafond de taille borne le reste.
#
# La phrase d'usage n'est pas de l'ornement : la difficulté, sous pression, n'est
# pas de lire un manuel mais de savoir LEQUEL ouvrir. La page d'accueil des
# manuels s'en sert.
# ── DOCUMENTATIONS RÉCUPÉRÉES PAR LEUR SOURCE ───────────────────────────────
#
# QUAND LE SITE N'EST PAS COPIABLE, ON PREND LA SOURCE.
#
# Quelques documentations du catalogue ne rendent presque rien en HTML : ce sont
# des applications JavaScript dont le sommaire est bâti côté navigateur. Une
# copie du site en rapporte alors une page, parfois zéro, et ni l'exploration ni
# le plan du site n'y changent quoi que ce soit.
#
# Mais elles sont TOUTES engendrées depuis un dépôt public de Markdown ou
# d'AsciiDoc. Prendre la source plutôt que le rendu a trois avantages pour un
# usage de crise :
#
#   - c'est du TEXTE : lisible dans n'importe quel éditeur, cherchable au grep,
#     sans dépendre d'un navigateur ni de JavaScript ;
#   - c'est petit : 7,5 Mo pour toute la documentation serveur d'Ubuntu ;
#   - c'est complet, là où un miroir de site est toujours partiel.
#
# Format : libellé | dossier | dépôt | sous-répertoire | catégorie | à quoi ça sert
# Le sous-répertoire évite de rapatrier ce qui ne sert pas — le dépôt de
# Raspberry Pi pèse 1 Go, dont l'essentiel en images de son site.
DOCS_GIT=(
  "Ubuntu Server — manuel complet|ubuntu-source|https://github.com/canonical/ubuntu-server-documentation.git|docs|Réinstaller|Toute la documentation serveur d'Ubuntu en Markdown. Le site, lui, n'est pas copiable."
  "Raspberry Pi — documentation officielle|raspberrypi-source|https://github.com/raspberrypi/documentation.git|documentation|Réinstaller|La documentation officielle en AsciiDoc — reconstruire l'arche elle-même."
  # Forgejo et non pagure : le dépôt pagure existe toujours mais ne contient plus
  # qu'un README annonçant la migration. Un dépôt qui répond n'est pas un dépôt
  # qui a le contenu — vérifié, 1 fichier là-bas contre 282 ici.
  "Fedora — procédures courantes|fedora-source|https://forge.fedoraproject.org/docs/quick-docs.git||Réinstaller|Les procédures courantes de Fedora, en AsciiDoc."
)

DOCUMENTATIONS=(
  "DFIR ORC — collecteur ANSSI|dfir-orc|https://dfir-orc.github.io/|150m|Constater avant de réparer|Collecter les artefacts d'un poste Windows suspect. À passer AVANT toute réparation : réparer détruit les traces."
  "CAINE|caine|https://www.caine-live.net/|60m|Constater avant de réparer|Démarrer sur une machine sans rien y écrire, monter les disques en lecture seule."
  "Kali Linux|kali|https://www.kali.org/docs/|200m|Constater avant de réparer|Mode « Live forensic » : ne monte aucun disque, n'active pas le swap."

  "SystemRescue|systemrescue|https://www.system-rescue.org/|120m|Réparer un système|Système qui ne démarre plus, table de partitions abîmée, GRUB à remettre. Le site porte aussi les guides de partitionnement et de LVM."
  "GParted|gparted|https://gparted.org/documentation.php|60m|Réparer un système|Redimensionner, déplacer, réparer des partitions."
  "Clonezilla|clonezilla|https://clonezilla.org/clonezilla-live-doc.php|100m|Réparer un système|Copier un disque entier avant d'y toucher, et le restaurer."

  "Ventoy — clés multi-ISO|ventoy|https://www.ventoy.net/en/doc_start.html|100m|Fabriquer un support|Une seule clé USB pour toutes les images du dépôt."
  "Rufus|rufus|https://github.com/pbatard/rufus/wiki|40m|Fabriquer un support|Graver une image sur clé depuis Windows."
  "KeePassXC|keepassxc|https://keepassxc.org/docs/|60m|Fabriquer un support|Ouvrir un export du coffre quand Vaultwarden ne démarre pas."

  "YunoHost|yunohost|https://doc.yunohost.org/|300m|Réinstaller|Le serveur de production. Sauvegarde, restauration, applications, domaines."
  "Debian — installation|debian|https://www.debian.org/releases/stable/amd64/|80m|Réinstaller|Le socle. Installation, partitionnement, réseau, amorçage."
  "Ubuntu Server|ubuntu|https://documentation.ubuntu.com/server/|200m|Réinstaller|Serveurs secondaires et postes."
  "Rocky Linux|rocky|https://docs.rockylinux.org/|200m|Réinstaller|Le monde Red Hat, substitut binaire de RHEL."
  "AlmaLinux|almalinux|https://wiki.almalinux.org/|100m|Réinstaller|L'autre substitut de RHEL."
  "NixOS|nixos|https://nixos.org/manual/nixos/stable/|100m|Réinstaller|Configuration déclarative — le projet Bureautix-Univ."

  # FEDORA ET RASPBERRY PI NE SONT PAS ICI, ET C'EST DÉLIBÉRÉ.
  #
  # Leurs sites refusent les automates, et pas par un simple filtre d'en-tête :
  #   - docs.fedoraproject.org répond 200 avec une page « Making sure you're not
  #     a bot! » (Anubis, une preuve de travail) — y compris sur son plan du
  #     site. Le « manuel » récupéré n'est alors que cette page de contrôle, et
  #     rien d'autre : une coquille qui se présente comme un manuel.
  #   - www.raspberrypi.com répond 403 même à un navigateur déclaré. Zéro
  #     fichier récupéré depuis le début.
  #
  # On ne cherche pas à passer outre : contourner une protection anti-automate
  # n'est ni correct ni durable — elle changera, et le dépôt se remettra à
  # mentir. Les deux documentations sont de toute façon COUVERTES, et mieux, par
  # leur source dans DOCS_GIT : 282 fichiers AsciiDoc pour Fedora Quick Docs,
  # 275 pour Raspberry Pi. Du texte, cherchable au grep, sans navigateur.
  #
  # Les laisser ici coûtait deux échecs par exécution — et un échec permanent
  # cesse d'être lu.

  # KIWIX N'EST PLUS ICI NON PLUS, et pour une raison différente des deux
  # précédentes : ce n'est pas qu'on ne PEUT pas le copier, c'est qu'il n'y a
  # rien à copier. wiki.kiwix.org est un wiki communautaire — « 2023 Hackathon »,
  # « Advertisement » — sans plan du site, avec quatre liens dans son HTML et un
  # crawl-delay de 10 s. Une page rapatriée, systématiquement.
  #
  # Surtout, personne n'en a besoin : les archives .zim sont servies par
  # kiwix-serve SUR L'ARCHE, à /kiwix/. On les lit en cliquant, pas en
  # consultant le manuel du lecteur.
)

documenter_git() {       # $1 libellé  $2 dossier  $3 dépôt  $4 sous-répertoire
  local libelle="$1" dossier="$2" depot="$3" sous="$4"
  local rep="$DOC/$dossier"

  if ! command -v git >/dev/null 2>&1; then
    mal "$libelle — git absent"
    return 1
  fi
  # Un dépôt déjà là se met à jour plutôt que de se recloner : quelques dizaines
  # de kilooctets au lieu de plusieurs mégaoctets.
  if [ -d "$rep/.git" ]; then
    if (cd "$rep" && git pull --quiet --depth 1 2>/dev/null); then
      # Le sommaire est refait même sans changement : c'est lui qui rend la
      # source consultable, et il coûte une fraction de seconde. La conversion,
      # elle, est incrémentale : seuls les fichiers plus récents que leur page.
      _nconv="$(convertir_source "$rep" "$libelle")"
      [ "${_nconv:-0}" -gt 0 ] && info "  $_nconv page(s) régénérée(s)"
      sommaire_source "$rep" "$libelle" "$depot"
      ok "$libelle — source à jour ($(du -sh "$rep" 2>/dev/null | cut -f1))"
      return 0
    fi
    info "  mise à jour impossible — on reclone"
    rm -rf "${rep:?}"
  fi

  bleu "$libelle — récupération de la source"
  mkdir -p "$(dirname "$rep")"
  rm -rf "${rep:?}" 2>/dev/null || true

  # « --depth 1 » : l'historique ne sert à rien ici, seul l'état courant compte.
  # « --filter=blob:none --sparse » quand on ne veut qu'un sous-répertoire : git
  # ne télécharge alors que les fichiers de ce répertoire. Sans cela, le dépôt de
  # Raspberry Pi ramènerait 1 Go pour quelques mégaoctets utiles.
  local ok_clone=1
  if [ -n "$sous" ]; then
    if git clone --quiet --depth 1 --filter=blob:none --sparse "$depot" "$rep" 2>/dev/null \
       && (cd "$rep" && git sparse-checkout set "$sous" 2>/dev/null); then
      ok_clone=0
    fi
  fi
  # Repli sur un clone superficiel complet : certains serveurs n'acceptent pas le
  # clone partiel, et mieux vaut tout prendre que ne rien avoir.
  if [ "$ok_clone" != 0 ]; then
    rm -rf "${rep:?}" 2>/dev/null || true
    git clone --quiet --depth 1 "$depot" "$rep" 2>/dev/null || {
      mal "$libelle — clone impossible ($depot)"
      return 1
    }
  fi

  # ON GARDE LE « .git », ET C'EST UN REVIREMENT ASSUMÉ.
  #
  # Le supprimer « pour rendre la place » rendait INATTEIGNABLE le chemin de
  # mise à jour juste au-dessus : sans dépôt, jamais de « git pull », donc un
  # clone intégral à CHAQUE exécution — 138 Mo pour Raspberry Pi, repris du
  # réseau et réécrits sur la carte SD toutes les nuits. Le code annonçait une
  # mise à jour incrémentale qu'il s'interdisait lui-même.
  #
  # Le clone est superficiel et filtré (« --depth 1 --filter=blob:none ») : son
  # historique tient en peu de place, sans commune mesure avec ce que coûte un
  # reclone quotidien.

  # « -path */.git/* -prune » : maintenant qu'on garde le dépôt, il ne doit
  # compter ni dans le décompte ni dans le sommaire.
  local n; n="$(find "$rep" -path '*/.git/*' -prune -o -type f \( -name '*.md' -o -name '*.adoc' -o -name '*.rst' -o -name '*.txt' \) -print 2>/dev/null | wc -l)"
  n="${n// /}"
  if [ "${n:-0}" -eq 0 ]; then
    mal "$libelle — aucun fichier de documentation dans le dépôt"
    return 1
  fi
  # Un mot d'explication sur place : celui qui ouvre ce dossier hors ligne doit
  # comprendre pourquoi il trouve du texte brut et non des pages web.
  printf 'DOCUMENTATION EN TEXTE SOURCE\n\nCe dossier contient la SOURCE de la documentation, telle que ses auteurs\nl%s ecrivent, et non une copie du site web.\n\nPourquoi : le site de ce projet est une application JavaScript dont le\nsommaire est construit par le navigateur. Aucun outil de copie hors ligne\nne peut le reproduire — nous avons mesure 0 a 1 page utile.\n\nComment le lire : ce sont des fichiers Markdown (.md) ou AsciiDoc (.adoc),\nlisibles tels quels dans n%simporte quel editeur, et cherchables :\n\n    grep -ri "votre recherche" .\n\nDepot d%sorigine : %s\n' \
    "'" "'" "'" "$depot" > "$rep/LISEZ-MOI-SOURCE.txt" 2>/dev/null || true

  local _nconv; _nconv="$(convertir_source "$rep" "$libelle")"
  if [ "${_nconv:-0}" -eq 0 ]; then
    avert "  aucun convertisseur : $libelle restera en texte brut"
    avert "    remède : sudo apt install pandoc ruby-asciidoctor"
  else
    info "  $_nconv page(s) HTML engendrées depuis la source"
  fi
  sommaire_source "$rep" "$libelle" "$depot"
  ok "$libelle — $n fichiers, $(du -sh "$rep" 2>/dev/null | cut -f1)"
}

# RENDRE LE TEXTE SOURCE LISIBLE, UNE FOIS POUR TOUTES.
#
# 816 fichiers Markdown et AsciiDoc servis en texte brut : ni titre, ni table
# des matières, ni lien cliquable d'un chapitre à l'autre. Techniquement
# présents, pratiquement inutilisables — et c'est le seul manuel qu'on ait pour
# Fedora et Raspberry Pi, dont les sites nous refusent.
#
# On convertit À LA COPIE, jamais à la lecture. Le jour de la crise il ne reste
# que des pages HTML statiques : pas de convertisseur à lancer, pas de
# JavaScript, rien à installer sur la machine qui consulte. C'est le même
# principe que la page de secours.
#
# Les sources restent à côté : elles sont cherchables au grep, ce que le HTML
# rend plus pénible.
_outils_conversion() {
  ASCIIDOCTOR=()
  if command -v asciidoctor >/dev/null 2>&1; then
    ASCIIDOCTOR=(asciidoctor)
  elif command -v ruby >/dev/null 2>&1; then
    # Debian livre le binaire du gem hors du PATH, sous un chemin qui porte son
    # numéro de version : on le cherche plutôt que de le figer.
    local g
    g="$(ls -d /usr/share/rubygems-integration/all/gems/asciidoctor-*/bin/asciidoctor 2>/dev/null | tail -1)"
    [ -n "$g" ] && ASCIIDOCTOR=(ruby "$g")
  fi
}

# UNE SEULE IDENTITÉ VISUELLE POUR TOUS LES MANUELS.
#
# Sans cela, trois rendus cohabitent : pandoc sort du Georgia serif sur 36 em,
# fond blanc cassé — un article universitaire de 2005 ; asciidoctor impose sa
# feuille de 29 Ko ; le sommaire a la sienne. Passer de l'un à l'autre donne
# l'impression de changer de site à
# chaque clic, et le lecteur perdait le fil de là où il était.
#
# Une feuille commune, écrite une fois par exécution à la racine des manuels et
# liée depuis chaque page. Elle pose le CADRE — fond, texte, largeur de lecture,
# liens, bandeau — et laisse à chaque convertisseur ses composants : tableaux,
# encadrés, coloration du code. Se battre avec eux là-dessus produirait des
# pages à moitié cassées qu'on ne verrait qu'à l'usage.
# LE BANDEAU, AUTONOME.
#
# Il est posé aussi bien sur nos pages converties que dans les MIROIRS de
# sites — Debian, Kali, Rocky — dont on ne connaît ni la feuille de style ni
# les classes. Ses styles sont donc en ligne, sans dépendre de rien : sur une
# page étrangère, une classe qu'on aurait définie ailleurs ne s'appliquerait
# pas, et le bandeau serait un tas de texte au sommet de la page.
#
# Les couleurs sont fixes et claires : la moitié des miroirs imposent un fond
# blanc, et un bandeau sombre y serait illisible.
bandeau() {              # $1 libellé  $2 section (peut être vide)  $3 remontée
  local libelle="$1" section="$2" haut="$3" s
  s="font:14px/1.4 ui-sans-serif,system-ui,-apple-system,\"Segoe UI\",Roboto,sans-serif;"
  s="${s}display:flex;gap:.9rem;align-items:baseline;flex-wrap:wrap;"
  s="${s}background:#eef1f4;color:#12171c;border-bottom:1px solid #d5dae0;"
  s="${s}padding:.5rem 1rem;margin:0"
  printf '<div class="arche-nav" style="%s">' "$s"
  printf '<span style="font-weight:600">%s</span>' "$libelle"
  [ -n "$section" ] && printf '<span style="color:#5c6773">%s</span>' "$section"
  printf '<span style="margin-left:auto;display:flex;gap:1rem">'
  printf '<a href="%sindex.html" style="color:#0f6f60;text-decoration:none">Sommaire</a>' "$haut"
  # « ${haut}../ » remonte à la racine des manuels : relatif à la page, donc
  # insensible au préfixe sous lequel on la sert — port 8080 ou /accueil/.
  printf '<a href="%s../" style="color:#0f6f60;text-decoration:none">Tous les manuels</a>' "$haut"
  # LA PORTE DE SORTIE ULTIME. « Sommaire » et « Tous les manuels » gardent
  # dans les manuels ; il manquait de quoi revenir au point de départ — celui
  # qui porte les adresses, l'annuaire et les deux guides. Deux crans au-dessus
  # de la page : les manuels, puis la racine.
  printf '<a href="%s../../" style="color:#0f6f60;text-decoration:none">Accueil</a>' "$haut"
  printf '</span></div>'
}

# LE BANDEAU SUR TOUS LES MANUELS, MIROIRS COMPRIS.
#
# Il n'était posé que sur les documentations converties depuis leur source —
# trois manuels sur dix-huit. Dans les quinze autres, des miroirs de sites, on
# entrait par un lien du sommaire et plus rien ne ramenait nulle part : ni au
# manuel, ni à la liste. Or ce sont les plus gros — certains miroirs comptent
# plus d'un millier de pages.
#
# On ne touche PAS à leur mise en page : seul le bandeau est inséré, avec ses
# styles en ligne. Le sommaire du miroir est sa propre page d'accueil, celle
# que « .entree » désigne — d'où le lien « Sommaire » qui pointe vers elle.
bandeaux_partout() {     # $1 dossier du manuel  $2 libellé
  local rep="$1" libelle="$2" f rel prof i haut entree pose=0
  [ -d "$rep" ] || return 0
  # La porte d'entrée du manuel, pour que « Sommaire » y mène vraiment.
  entree="index.html"
  [ -s "$rep/.entree" ] && entree="$(head -1 "$rep/.entree")"

  while IFS= read -r f; do
    grep -q 'class="arche-nav"' "$f" 2>/dev/null && continue
    rel="${f#"$rep"/}"
    prof="$(printf '%s' "$rel" | tr -cd '/' | wc -c)"
    haut=""
    i=0
    while [ "$i" -lt "${prof:-0}" ]; do haut="../$haut"; i=$((i + 1)); done
    # Le lien « Sommaire » vise la porte d'entrée réelle, pas un index.html
    # qui n'existe peut-être pas à la racine du miroir.
    local vers="$haut$entree"
    sed -i "0,/<body[^>]*>/s||&$(bandeau "$libelle" "" "$haut" \
      | sed "s@href=\"${haut}index.html\"@href=\"$vers\"@")|" "$f" 2>/dev/null || true
    pose=$((pose + 1))
  done < <(find "$rep" -path '*/.git/*' -prune -o -name '*.html' -print 2>/dev/null)
  printf '%s' "$pose"
}

feuille_manuels() {
  local f="$DOC/manuels.css"
  cat > "$f" <<'CSS'
/* Manuels hors ligne de l'arche — feuille commune. Aucune ressource externe. */
:root{
  --bg:#0d1013; --surf:#151b21; --hair:rgba(255,255,255,.12);
  --txt:#eef2f6; --dim:#93a0ad; --acc:#4fc3b0;
}
@media (prefers-color-scheme:light){
  :root{--bg:#f6f7f9; --surf:#fff; --hair:rgba(0,0,0,.12);
        --txt:#12171c; --dim:#5c6773; --acc:#0f6f60}
}
html,body{background:var(--bg) !important;color:var(--txt) !important}
body{font-family:ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,sans-serif !important;
  font-size:17px;line-height:1.65;margin:0 !important;max-width:none !important;
  padding:0 !important}
a{color:var(--acc)}
h1,h2,h3,h4{color:var(--txt);line-height:1.25}
code,pre,kbd,tt{font-family:ui-monospace,SFMono-Regular,Menlo,monospace}

/* Le bandeau : où je suis, et comment j'en sors. */
.arche-nav{position:sticky;top:0;z-index:99;display:flex;gap:.9rem;
  align-items:baseline;flex-wrap:wrap;
  background:var(--surf);border-bottom:1px solid var(--hair);
  padding:.6rem 1.2rem;font-size:.9rem}
.arche-nav .manuel{font-weight:600;color:var(--txt)}
.arche-nav .fil{color:var(--dim)}
.arche-nav .liens{margin-left:auto;display:flex;gap:1rem}
.arche-nav a{text-decoration:none}
.arche-nav a:hover{text-decoration:underline}

/* Le corps de page, quel que soit le convertisseur. */
#content,.wrap,body>h1,body>h2,body>p,body>ul,body>ol,body>pre,body>table,
body>div:not(.arche-nav):not(.wrap){max-width:52rem;margin-left:auto;margin-right:auto;
  padding-left:1.2rem;padding-right:1.2rem}
#content{padding-top:1.5rem;padding-bottom:4rem}
#header,#footer{max-width:52rem;margin:0 auto;padding:0 1.2rem}
#toc{background:var(--surf);border:1px solid var(--hair);border-radius:.7rem;
  padding:.9rem 1.1rem}
table{border-collapse:collapse}
th,td{border-color:var(--hair) !important}
pre,.listingblock pre,.literalblock pre{background:var(--surf) !important;
  border:1px solid var(--hair) !important;border-radius:.5rem;padding:.8rem 1rem !important;
  overflow-x:auto}
blockquote,.quoteblock{border-left:.2rem solid var(--hair);padding-left:1rem;color:var(--dim)}
img{max-width:100%;height:auto}
@media print{
  :root{--bg:#fff;--surf:#fff;--txt:#000;--dim:#444;--acc:#000;--hair:#bbb}
  .arche-nav{display:none}
}
CSS
  chmod 644 "$f" 2>/dev/null || true
}

convertir_source() {     # $1 répertoire  $2 libellé
  local rep="$1" libelle_nav="${2:-Manuel}" n=0 f cible fmt prefixe_nav=""
  _outils_conversion
  feuille_manuels

  # ── AsciiDoc ──────────────────────────────────────────────────────────────
  # UNE SEULE invocation pour tous les fichiers : démarrer Ruby coûte près
  # d'une seconde, et Raspberry Pi en compte 275 — quatre minutes de démarrages
  # contre quelques secondes de travail réel.
  #
  # « -a webfonts! » : sans lui, asciidoctor met un @import vers Google Fonts
  # dans chaque page. Sur une machine sans Internet, chaque ouverture attend
  # une réponse qui ne viendra pas. Avec l'option, la ligne subsiste mais en
  # COMMENTAIRE CSS — vérifié : inerte, aucune requête.
  #
  # « -a outfilesuffix=.html » : sans lui, les renvois d'un chapitre à l'autre
  # pointent vers des « .adoc » que le navigateur téléchargerait.
  if [ "${#ASCIIDOCTOR[@]}" -gt 0 ]; then
    local -a adocs=()
    while IFS= read -r f; do
      cible="${f%.adoc}.html"
      [ -f "$cible" ] && [ "$cible" -nt "$f" ] && continue
      adocs+=("$f")
    done < <(find "$rep" -path '*/.git/*' -prune -o -name '*.adoc' -print 2>/dev/null)
    if [ "${#adocs[@]}" -gt 0 ]; then
      "${ASCIIDOCTOR[@]}" -q -a webfonts! -a outfilesuffix=.html \
        --safe-mode=unsafe "${adocs[@]}" >/dev/null 2>&1 || true
      n=$(( n + ${#adocs[@]} ))
    fi
  fi

  # ── Markdown et reStructuredText ──────────────────────────────────────────
  if command -v pandoc >/dev/null 2>&1; then
    while IFS= read -r f; do
      cible="${f%.*}.html"
      [ -f "$cible" ] && [ "$cible" -nt "$f" ] && continue
      case "$f" in
        *.md)  fmt=markdown ;;
        *.rst) fmt=rst ;;
        *)     continue ;;
      esac
      pandoc --standalone --quiet -f "$fmt" -t html5 \
             --metadata title="$(basename "${f%.*}")" \
             -o "$cible" "$f" 2>/dev/null || continue
      n=$(( n + 1 ))
    done < <(find "$rep" -path '*/.git/*' -prune -o \
                  \( -name '*.md' -o -name '*.rst' \) -print 2>/dev/null)
  fi

  # ── SERVIR LES PAGES, JAMAIS LES SOURCES ─────────────────────────────────
  #
  # Une passe finale sur TOUT l'arbre, et non page par page à la sortie de
  # pandoc : asciidoctor n'y passait pas, et les renvois « link:fichier.adoc »
  # qu'il ne convertit pas restent tels quels. Résultat : une trentaine de liens
  # par manuel font TÉLÉCHARGER un fichier de texte
  # au lieu d'ouvrir la page suivante. Le sommaire marchait, la navigation non —
  # et c'est la navigation qu'on utilise quand on lit vraiment.
  #
  # « [^":]* » écarte les adresses absolues : un lien vers le .adoc d'un dépôt
  # sur Internet doit rester ce qu'il est, on ne l'a pas copié.
  find "$rep" -path '*/.git/*' -prune -o -name '*.html' -print0 2>/dev/null \
    | xargs -0 -r sed -i -E 's/(href="[^":]*)\.(md|adoc|rst)(#[^"]*)?"/\1.html\3"/g' \
      2>/dev/null || true

  # ── UN CHEMIN DE RETOUR DANS CHAQUE PAGE ─────────────────────────────────
  #
  # Les convertisseurs produisent des pages AUTONOMES : une fois dans un
  # chapitre, plus rien ne ramène au sommaire ni ne dit de quel manuel il
  # s'agit. On lit, puis on est bloqué — il faut connaître l'adresse du
  # sommaire pour en sortir, ce qui est exactement ce qu'on ne sait pas en
  # crise.
  #
  # Le bandeau est posé APRÈS conversion, dans la page produite : les
  # convertisseurs n'offrent pas de gabarit et l'on ne veut pas dépendre du
  # leur. La profondeur se compte en barres obliques, puisque le sommaire est à
  # la racine du manuel.
  # Le préfixe commun, calculé une fois pour le fil d'Ariane des pages — même
  # raison que dans le sommaire : « documentation › asciidoc › » partout n'aide
  # personne à savoir où il est.
  prefixe_nav="$(cd "$rep" && find . -path './.git/*' -prune -o -type f \
      \( -name '*.md' -o -name '*.adoc' -o -name '*.rst' \) -print 2>/dev/null \
    | sed 's|^\./||' | sed -n 's|/[^/]*$||p' \
    | awk 'NR==1{p=$0} NR>1{while (p!="" && index($0"/",p"/")!=1) sub(/\/?[^\/]*$/,"",p)} END{print p}')"

  local rel prof i haut ban
  while IFS= read -r f; do
    # LE GARDE DOIT PORTER SUR LE BANDEAU COURANT, pas sur un ancien.
    #
    # Un garde laissé sur l'identifiant d'un bandeau précédent fait sauter TOUTES
    # les pages, qui le portent déjà : le nouveau bandeau et la feuille commune ne
    # sont posés nulle part, et rien ne le signale. Cela se voit dans le rendu, pas
    # dans le code.
    grep -q 'class="arche-nav"' "$f" 2>/dev/null && continue
    # On retire le bandeau de la version précédente, sinon les deux coexistent.
    sed -i 's@<div id="retour-sommaire"[^>]*>.*\?</div>@@' "$f" 2>/dev/null || true
    rel="${f#"$rep"/}"
    prof="$(printf '%s' "$rel" | tr -cd '/' | wc -c)"
    haut=""
    i=0
    while [ "$i" -lt "${prof:-0}" ]; do haut="../$haut"; i=$((i + 1)); done
    # OÙ JE SUIS, ET COMMENT J'EN SORS. Le premier bandeau ne disait que
    # « sommaire » : on savait revenir, pas où l'on était ni de quel manuel il
    # s'agissait. Trois repères suffisent — le manuel, la section, les portes.
    local section
    section="$(dirname "$rel")"
    if [ "$section" = "." ]; then
      section=""
    else
      [ -n "$prefixe_nav" ] && section="${section#"$prefixe_nav"}"
      section="${section#/}"
      section="$(printf '%s' "$section" | awk -F/ '{
        for (i = 1; i <= NF; i++) { sub(/^_+/, "", $i); gsub(/_/, " ", $i) }
        s = $1; for (i = 2; i <= NF; i++) s = s " › " $i; print s }')"
    fi
    ban="$(bandeau "$libelle_nav" "$section" "$haut")"
    sed -i "0,/<body[^>]*>/s||&${ban}|" "$f" 2>/dev/null || true
    # La feuille commune, liée et non recopiée : une seule à corriger.
    # « 0,|re|s|| » est REFUSÉ par GNU sed — et comme la sortie d'erreur est jetée,
    # le lien ne serait jamais posé sans que rien ne le dise. À vérifier sur la
    # machine cible : BSD sed, lui, ne connaît pas cette adresse du tout, si bien
    # qu'un essai sur macOS ne prouve rien. Il n'y a qu'une balise
    # </head> par document, donc une substitution simple suffit.
    grep -q 'manuels\.css' "$f" 2>/dev/null \
      || sed -i "s@</head>@<link rel=\"stylesheet\" href=\"${haut}../manuels.css\"></head>@" "$f" 2>/dev/null || true
  done < <(find "$rep" -path '*/.git/*' -prune -o -name '*.html' -print \
           | grep -v "^$rep/index.html$")

  printf '%s' "$n"
}

# UNE SOURCE SANS SOMMAIRE N'EST PAS CONSULTABLE.
#
# 275 fichiers AsciiDoc pour Raspberry Pi, 282 pour Fedora : sur le disque, mais
# rien n'y menait. L'index général ne listait que les miroirs de sites, et un
# arborescence nue dans le navigateur n'est pas un manuel — le jour où l'on en a
# besoin, on ne fouille pas un répertoire, on cherche une réponse.
#
# On écrit donc un sommaire, groupé par répertoire, qui rend la source
# navigable au clic. nginx sert ces fichiers en texte brut (voir
# zz-arche-secours.conf) : ils s'affichent au lieu de se télécharger.
sommaire_source() {      # $1 répertoire  $2 libellé  $3 dépôt d'origine
  local rep="$1" libelle="$2" depot="$3"
  local f="$rep/index.html"
  {
    printf '<!doctype html><html lang="fr"><head><meta charset="utf-8">'
    printf '<meta name="viewport" content="width=device-width,initial-scale=1">'
    printf '<title>%s — source</title><style>' "$libelle"
    printf ':root{--bg:#0f1115;--surf:#161a21;--txt:#e6e9ef;--dim:#98a2b3;--acc:#7cc4ff;--hair:#232936}'
    printf '@media(prefers-color-scheme:light){:root{--bg:#fbfbfd;--surf:#fff;--txt:#1a1d24;--dim:#5b6472;--acc:#0b62c4;--hair:#e3e6ec}}'
    printf 'body{margin:0;background:var(--bg);color:var(--txt);font:15px/1.6 ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}'
    printf '.wrap{max-width:60rem;margin:0 auto;padding:2.5rem 1.5rem 5rem}'
    printf 'h1{font-size:1.6rem;margin:0 0 .3rem}h2{font-size:.95rem;color:var(--dim);margin:2rem 0 .5rem;font-family:ui-monospace,monospace}'
    printf '.sous{color:var(--dim);margin-bottom:1.5rem}'
    printf '.note{background:var(--surf);border:1px solid var(--hair);border-radius:.8rem;padding:1rem 1.2rem;margin-bottom:2rem;color:var(--dim);font-size:.93rem}'
    printf 'code{font-family:ui-monospace,monospace;color:var(--txt)}'
    printf 'ul{list-style:none;padding:0;margin:0;display:grid;grid-template-columns:repeat(auto-fill,minmax(24rem,1fr));gap:.15rem}'
    printf 'li a{display:block;color:var(--acc);text-decoration:none;padding:.35rem .6rem;border-radius:.4rem}'
    printf 'li a:hover{background:var(--surf);text-decoration:underline}'
    printf '@media print{:root{--bg:#fff;--surf:#fff;--txt:#000;--dim:#444;--acc:#000;--hair:#bbb}}'
    printf '</style><link rel="stylesheet" href="../manuels.css"></head>'
    printf '<body><div class="arche-nav"><span class="manuel">%s</span>' "$libelle"
    printf '<span class="liens"><a href="../">Tous les manuels</a>'
    printf '<a href="../../">Accueil</a></span></div>'
    printf '<div class="wrap">'
    printf '<h1>%s</h1><div class="sous">Documentation en texte source.</div>' "$libelle"
    printf '<div class="note">Ce sont les fichiers que les auteurs écrivent, et non une copie '
    printf 'du site — celui-ci n%sest pas copiable hors ligne. Ils s%saffichent tels quels dans le ' "'" "'"
    printf 'navigateur ; leur source est dans le même dossier. Pour chercher dans l%sensemble : <code>grep -ri "votre recherche" .</code> ' "'"
    printf 'depuis <code>%s</code>.<br>Origine : %s</div>' "$rep" "$depot"

    local liste
    liste="$(cd "$rep" && find . -path './.git/*' -prune -o -type f \
             \( -name '*.md' -o -name '*.adoc' -o -name '*.rst' \) -print \
             2>/dev/null | sed 's|^\./||' \
             | awk -F/ '{d=$0; if (sub(/\/[^\/]*$/, "", d) == 0) d="."; print d "\t" $0}' \
             | LC_ALL=C sort | cut -f2-)"
    [ -n "$liste" ] || return 0

    # LE PRÉFIXE COMMUN NE DIT RIEN — on le retire.
    #
    # « documentation › asciidoc › » ouvrait les quarante-six sections de
    # Raspberry Pi, « modules › ROOT › » celles de Fedora. Répété partout, un
    # chemin n'informe plus : il occupe la moitié de la ligne et repousse à
    # droite la seule partie qui distingue une section d'une autre.
    local prefixe
    prefixe="$(printf '%s\n' "$liste" | sed -n 's|/[^/]*$||p' \
      | awk 'NR==1{p=$0} NR>1{while (p!="" && index($0"/",p"/")!=1) sub(/\/?[^\/]*$/,"",p)} END{print p}')"

    local dossier_courant="__" d
    # Trié par chemin : les fichiers d'un même répertoire se suivent, et l'ordre
    # est celui que l'auteur a donné à son arborescence.
    while IFS= read -r fichier; do
      d="$(dirname "$fichier")"
      if [ "$d" != "$dossier_courant" ]; then
        [ "$dossier_courant" != "__" ] && printf '</ul>'
        # « documentation/asciidoc/computers/raspberry-pi » se lit mal en
        # titre de section. On garde le chemin — il situe — mais on l'allège.
        local intitule
        if [ "$d" = "." ]; then
          intitule="À la racine du dépôt"
        else
          intitule="$d"
          [ -n "$prefixe" ] && intitule="${intitule#"$prefixe"}"
          intitule="${intitule#/}"
          [ -n "$intitule" ] || intitule="Documentation"
          # SEGMENT PAR SEGMENT, et non par substitutions enchaînées.
          #
          # Une chaîne de « sed » qui remplace les barres, puis les tirets bas,
          # puis les espaces doubles, finit par se marcher dessus : elle a
          # produit « pages›  partials » et « partialsdelete » — un nom de
          # dossier qui n'existe pas. Découper sur « / » et nettoyer chaque
          # morceau ne peut pas produire ce genre de surprise.
          intitule="$(printf '%s' "$intitule" | awk -F/ '{
            for (i = 1; i <= NF; i++) { sub(/^_+/, "", $i); gsub(/_/, " ", $i) }
            s = $1
            for (i = 2; i <= NF; i++) s = s " › " $i
            print s
          }')"
        fi
        printf '<h2>%s</h2><ul>' "$intitule"
        dossier_courant="$d"
      fi
      # LA PAGE, ET RIEN D'AUTRE SUR LA LIGNE.
      #
      # Un petit lien « source » vers le .md ou le .adoc sur chaque entrée fait
      # autant de liens en trop qu'il y a de lignes, et surtout donne l'impression
      # que le manuel n'a pas été converti. Les sources sont dans les
      # mêmes dossiers, à côté des pages, et la note en tête le dit avec la
      # commande pour les chercher.
      # LE TITRE DU DOCUMENT, PAS LE NOM DU FICHIER.
      #
      # « about », « details », « getting-started » : trois cents entrées de ce
      # genre ne forment pas un sommaire, elles forment une liste de fichiers.
      # Le convertisseur a mis le vrai titre dans <title> — on le reprend, et le
      # nom de fichier ne sert plus que de repli.
      local page="${fichier%.*}.html" titre
      if [ -f "$rep/$page" ]; then
        titre="$(sed -n 's|.*<title>\(.*\)</title>.*|\1|p' "$rep/$page" 2>/dev/null | head -1)"
        [ -n "$titre" ] || titre="$(basename "${fichier%.*}")"
        printf '<li><a href="%s">%s</a></li>' "$page" "$titre"
      else
        printf '<li><a href="%s">%s</a></li>' "$fichier" "$(basename "$fichier")"
      fi
    # TRIER PAR RÉPERTOIRE, PUIS PAR NOM — et non par chemin entier.
    #
    # Un tri sur le chemin entrelace les groupes : « accessories/ai-camera.adoc »
    # se glisse entre « accessories/ai-camera/about.adoc » et le fichier suivant
    # du même dossier, si bien que le sommaire rouvrait trois fois la même
    # section.
    #
    # On préfixe donc chaque ligne de son répertoire et l'on trie là-dessus :
    # chaque dossier apparaît une fois, avec tout ce qu'il contient.
    done <<< "$liste"
    [ "$dossier_courant" != "__" ] && printf '</ul>'

    # UN FILTRE, PARCE QUE DEUX CENT QUATRE-VINGTS ENTRÉES NE SE PARCOURENT PAS.
    #
    # Fedora tient 282 pages en six sections : on fait défiler, on ne trouve
    # pas. Le champ est CRÉÉ PAR LE SCRIPT, jamais écrit dans le HTML : sans
    # JavaScript il n'apparaît pas du tout, plutôt que d'afficher une boîte
    # inerte qui promet une recherche qu'elle ne fera pas. La liste complète
    # reste alors visible, et le navigateur sait chercher dans une page.
    printf '<script>'
    printf '(function(){var w=document.querySelector(".wrap");if(!w)return;'
    printf 'var f=document.createElement("input");f.type="search";'
    printf 'f.placeholder="Filtrer — tapez un mot du titre";'
    printf 'f.setAttribute("aria-label","Filtrer les pages du manuel");'
    printf 'f.style.cssText="width:100%%;padding:.6rem .8rem;margin:0 0 1.5rem;'
    printf 'font:inherit;border-radius:.6rem;border:1px solid var(--hair);'
    printf 'background:var(--surf);color:var(--txt)";'
    printf 'var n=w.querySelector(".note");'
    printf 'n?n.parentNode.insertBefore(f,n.nextSibling):w.appendChild(f);'
    printf 'var s=[].slice.call(w.querySelectorAll("h2"));'
    printf 'f.addEventListener("input",function(){'
    printf 'var q=f.value.toLowerCase();'
    printf 's.forEach(function(h){var u=h.nextElementSibling,v=0;'
    printf '[].forEach.call(u.querySelectorAll("li"),function(l){'
    printf 'var m=l.textContent.toLowerCase().indexOf(q)>=0;'
    printf 'l.style.display=m?"":"none";if(m)v++;});'
    printf 'h.style.display=v?"":"none";u.style.display=v?"":"none";});});'
    printf '})();'
    printf '</script>'
    printf '</div></body></html>'
  } > "$f" 2>/dev/null || return 0
  chmod 644 "$f" 2>/dev/null || true
  printf 'index.html\n' > "$rep/.entree" 2>/dev/null || true
}

# Écrit « .entree » — la page par où l'on entre dans un manuel — à partir de
# l'URL d'où le miroir est parti. Sans réseau si l'adresse déclarée suffit ; on
# ne résout la redirection que si aucun fichier ne correspond, parce que c'est
# justement le cas où le miroir vit sous un autre hôte (Ubuntu Server).
#
# TROIS ÉCRITURES POUR UNE MÊME ADRESSE, et il faut les essayer toutes :
#
#   .../server/docs/          -> server/docs/index.html      (URL de répertoire)
#   .../pbatard/rufus/wiki    -> pbatard/rufus/wiki.html      (« -E » ajoute .html)
#   .../KeePassXC_Getting.html-> tel quel                     (extension déjà là)
#
# Ne tenter que la première laissait Rufus sans porte d'entrée : l'index
# retombait alors sur « le index.html le moins profond » et proposait la page
# GitHub Actions du projet — des journaux de compilation en guise de manuel.
entree_manuel() {        # $1 répertoire du manuel  $2 url déclarée
  local rep="$1" url="$2" essai u e
  for essai in "$url" "@redirection"; do
    if [ "$essai" = "@redirection" ]; then
      essai="$(curl -sIL -o /dev/null -w '%{url_effective}' --max-time 25 "$url" 2>/dev/null || true)"
      [ -n "$essai" ] && [ "$essai" != "$url" ] || break
    fi
    u="${essai#*://}"; u="${u%%\?*}"; u="${u%%#*}"
    [ -n "$u" ] || continue
    for e in "${u%/}/index.html" "${u%/}.html" "$u"; do
      [ -f "$rep/$e" ] || continue
      printf '%s\n' "$e" > "$rep/.entree" 2>/dev/null || true
      return 0
    done
  done
  # Aucune correspondance : mieux vaut pas de fichier qu'un fichier qui ment —
  # l'index retombera sur la page la plus proche de la racine.
  rm -f "$rep/.entree" 2>/dev/null || true
  return 0
}

documenter() {           # $1 libellé  $2 dossier  $3 url  $4 plafond
  local libelle="$1" dossier="$2" url="$3" plafond="$4"
  local rep="$DOC/$dossier"

  # « DÉJÀ PRÉSENTE » NE DOIT PAS FIGER UN MIROIR RATÉ.
  #
  # La présence d'un seul fichier .html suffisait à passer. Conséquence : un
  # dossier d'une page — Ubuntu, Fedora — était considéré comme fait, à jamais.
  # Et le correctif du plan du site, qui fait passer YunoHost de 8 à 123 pages,
  # n'aurait jamais été appliqué : le dossier existait, donc on sautait.
  # Cela se voit dans le bilan, pas dans le code.
  #
  # On ne saute donc que si le miroir est jugé EXPLOITABLE selon les mêmes
  # critères qu'à l'arrivée — sinon on réessaie, ce qui est le seul moyen qu'une
  # amélioration du script profite à ce qui a échoué avant elle.
  # PRA_DOC_REFAIRE=1 refait TOUS les miroirs, sans se demander s'ils sont bons.
  #
  # Sans cet interrupteur, deux heuristiques se contrarient : le seuil de taille
  # protège les manuels en page unique — NixOS, 28 Mo — mais fige du même coup
  # YunoHost à 8 pages et 15 Mo, alors que le plan du site le porterait à 123.
  # Plutôt que d'affiner une règle qui devrait deviner l'intention, on la rend
  # explicite : après une amélioration du script, on refait, et on voit.
  if [ -d "$rep" ] && [ "${PRA_DOC_REFAIRE:-0}" != "1" ]; then
    local n0 ko0
    n0="$(find "$rep" -name '*.html' 2>/dev/null | wc -l)"; n0="${n0// /}"
    ko0="$(du -sk "$rep" 2>/dev/null | cut -f1)"; ko0="${ko0:-0}"
    if [ "$n0" -ge "${PRA_DOC_SEUIL:-5}" ] || [ "$ko0" -ge "${PRA_DOC_SEUIL_KO:-2048}" ]; then
      # LA PORTE D'ENTRÉE SE RÉPARE SANS RIEN RETÉLÉCHARGER.
      #
      # Elle n'était écrite qu'au moment du miroir. Or un manuel déjà présent
      # est SAUTÉ : les treize manuels copiés avant cette idée n'auraient jamais
      # eu la leur, sauf à tout refaire — deux heures de réseau pour produire
      # dix-sept fichiers d'une ligne. On la recalcule ici : le nom du fichier
      # se déduit de l'URL, et il suffit de vérifier qu'il existe.
      entree_manuel "$rep" "$url"
      ok "$libelle — documentation déjà présente ($n0 pages)"
      return 0
    fi
    if [ "$n0" -gt 0 ]; then
      info "$libelle — miroir précédent trop maigre ($n0 page(s)) : nouvelle tentative"
      rm -rf "${rep:?}"/* 2>/dev/null || true
    fi
  fi

  bleu "$libelle — copie de la documentation"
  mkdir -p "$rep"
  # Declaree ICI et non plus bas : le bloc « plan du site » ci-dessous en a
  # besoin. Plusieurs sites — Raspberry Pi notamment — repondent 403 a un client
  # qui s'annonce comme wget. Se presenter en navigateur n'est pas un
  # contournement de protection : la page est publique et servie telle quelle,
  # c'est un filtre sur l'en-tete, pas un controle d'acces.
  local ua="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Firefox/128.0"

  # ── DEUX CAUSES DE MIROIRS VIDES, DEUX PARADES ──────────────────────────
  #
  # Certains miroirs ne ramènent qu'une poignée de pages là où d'autres en
  # donnent des centaines. Un manuel d'une page qui prétend documenter un système
  # entier est PLUS dangereux qu'un manuel absent : on ne cherchera pas ailleurs
  # le jour où on en a besoin.
  #
  # CAUSE 1 — LA REDIRECTION VERS UN AUTRE HÔTE.
  # « documentation.ubuntu.com/server/ » redirige vers « ubuntu.com/server/docs/ ».
  # wget ne franchit pas les hôtes par défaut : il prend la page d'arrivée, puis
  # rejette TOUS ses liens comme externes. On résout donc l'URL finale d'abord, et
  # l'on part de là — le miroir se fait alors sur le bon hôte.
  local depart="$url" finale
  finale="$(curl -sIL -o /dev/null -w '%{url_effective}' --max-time 25 "$url" 2>/dev/null || true)"
  if [ -n "$finale" ] && [ "$finale" != "$url" ]; then
    local h1 h2
    h1="$(printf '%s' "$url"    | sed -E 's|https?://([^/]+).*|\1|')"
    h2="$(printf '%s' "$finale" | sed -E 's|https?://([^/]+).*|\1|')"
    if [ "$h1" != "$h2" ]; then
      info "  redirection vers un autre hôte ($h2) — on part de l'URL finale"
      depart="$finale"
    fi
  fi

  # CAUSE 2 — LA NAVIGATION CONSTRUITE EN JAVASCRIPT.
  # doc.yunohost.org sert une coquille avec UN SEUL lien dans son HTML : c'est un
  # site Docusaurus, dont le sommaire est bâti côté navigateur. wget ne voit rien
  # à suivre. Mais ces générateurs publient un PLAN DU SITE complet — 123 URL pour
  # YunoHost, 63 pour KeePassXC — et wget sait consommer une liste d'adresses.
  #
  # On tente donc le plan du site avant le parcours récursif. S'il existe, on ne
  # devine plus la structure : on la lit.
  local racine liste n_plan=0 chemin
  racine="$(printf '%s' "$depart" | sed -E 's|(https?://[^/]+).*|\1|')"
  chemin="$(printf '%s' "$depart" | sed -E 's|https?://[^/]+||; s|/$||')"
  liste="$(mktemp)"

  # OÙ CHERCHER LE PLAN. Un seul emplacement ne suffit pas : mesuré sur les 18
  # documentations du catalogue, trois sites le publient sous un autre nom et ne
  # le déclarent que dans robots.txt — NixOS (sitemap-index.xml), Raspberry Pi
  # (sitemap_index.xml), Ubuntu (doc-sitemap.xml). Chercher au seul
  # « /sitemap.xml » les manquait tous les trois.
  local candidats=""
  candidats="$(curl -fsL --max-time 15 "$racine/robots.txt" 2>/dev/null \
                | grep -ioE '^[[:space:]]*sitemap:[[:space:]]*\S+' \
                | sed -E 's/^[[:space:]]*[Ss]itemap:[[:space:]]*//' || true)"
  candidats="$candidats
$racine/sitemap.xml
$racine/sitemap_index.xml
$racine/sitemap-index.xml"

  # SUIVRE LES INDEX, UN NIVEAU. Plusieurs plans ne sont qu'un sommaire pointant
  # vers d'autres plans : Ubuntu en compte 40, NixOS un seul qui porte 258
  # adresses. S'arrêter au sommaire donnerait une liste d'URL de plans, pas de
  # pages — et un miroir de fichiers XML.
  local u contenu
  while IFS= read -r u; do
    [ -n "${u// /}" ] || continue
    contenu="$(curl -fsL --max-time 30 "$u" 2>/dev/null || true)"
    [ -n "$contenu" ] || continue
    if printf '%s' "$contenu" | grep -q '<sitemapindex'; then
      # Sommaire : on déplie chaque sous-plan, dans la limite du raisonnable.
      printf '%s' "$contenu" | grep -oE '<loc>[^<]+</loc>' | sed -E 's|</?loc>||g' \
        | head -20 | while IFS= read -r sous; do
            curl -fsL --max-time 30 "$sous" 2>/dev/null \
              | grep -oE '<loc>[^<]+</loc>' | sed -E 's|</?loc>||g'
          done
    else
      printf '%s' "$contenu" | grep -oE '<loc>[^<]+</loc>' | sed -E 's|</?loc>||g'
    fi
  done <<< "$candidats" \
    | grep -F "$chemin" | sort -u | head -600 > "$liste" 2>/dev/null || true
  # « grep -c » IMPRIME DÉJÀ SON ZÉRO. Le « || echo 0 » en ajoutait un second
  # quand le plan était vide : la variable valait « 0\n0 », et le test qui suit
  # rendait « [: 0 0: integer expression expected » sur la sortie d'erreur. Le
  # repli sur l'exploration jouait quand même — le défaut était bruyant plutôt
  # que grave — mais un message d'erreur qu'on apprend à ignorer est un message
  # qu'on n'ignorera pas seulement celui-là.
  n_plan=0
  [ -s "$liste" ] && n_plan="$(grep -c . "$liste" 2>/dev/null || true)"
  case "$n_plan" in ''|*[!0-9]*) n_plan=0 ;; esac

  if [ "$n_plan" -gt 5 ]; then
    info "  plan du site : $n_plan adresses — copie par liste plutôt que par exploration"
    (cd "$rep" && wget -q -i "$liste" -k -p -E -nc --restrict-file-names=windows \
        --quota="$plafond" --timeout=20 --tries=2 --user-agent="$ua" \
        --reject "*.iso,*.zip,*.exe,*.7z,*.img,*.tar.gz,*.deb,*.rpm,*.dd,*.gz,*.xz,*.bz2,*.dmg,*.msi,*.vdi,*.ova,*.qcow2,*.mp4,*.webm" \
        --reject-regex "\.(dd|img|iso)(\.|$)" 2>/dev/null) || true
  fi
  rm -f "$liste"
  url="$depart"
  # -np n'écarte que les répertoires parents ; -E ajoute l'extension .html aux
  # pages servies sans elle, sans quoi elles ne s'ouvrent pas depuis un disque.
  # -k convertit les liens : c'est ce qui rend la copie NAVIGABLE hors ligne,
  # et sans quoi on obtient un tas de fichiers qui pointent tous vers Internet.
  # Le rejet des gros formats évite d'aspirer des images disque au passage.
  # Plusieurs sites — celui de Raspberry Pi notamment — répondent 403 à un
  # client qui s'annonce comme wget. Se présenter en navigateur n'est pas un
  # contournement de protection : la page est publique et servie telle quelle,
  # c'est un filtre sur l'en-tête, pas un contrôle d'accès.
  # Le plafond de wget n'est vérifié qu'ENTRE deux fichiers : un seul gros
  # fichier le dépasse largement avant d'être compté. CAINE a ainsi ramené une
  # image disque de 760 Mo — « nbcaine1.5.dd.html.gz » — sous un plafond de
  # 60 Mo, parce que l'extension composée échappait à la liste de rejets.
  # D'où le rejet par EXPRESSION en plus de la liste. ATTENTION : il ne SUFFIT
  # pas — le même fichier de 760 Mo revient malgré lui, parce qu'un nom en
  # « .html.gz » passe pour du HTML, que
  # wget télécharge avant d'appliquer quoi que ce soit. Le vrai garde-fou est la
  # purge par taille, plus bas, qui elle ne suppose rien.
  #
  # IL N'Y A PAS DE « --max-file-size » DANS WGET. Ajouter cette option en croyant
  # qu'elle existe casse tout : wget refuse toute option inconnue et sort
  # AUSSITÔT, sans rien télécharger. Chaque miroir échoue alors en « aucune page
  # récupérée », et seuls survivent les manuels récupérés AVANT l'ajout — un
  # dépôt qui se vide sans qu'une seule erreur ne paraisse anormale.
  #
  # La leçon dépasse le cas : une option inventée ne produit pas d'erreur visible
  # ici, parce que la sortie de wget est jetée (2>/dev/null) et que l'échec se
  # confond avec « le site n'a rien donné ». Voir tests/test_wget_options.py, qui
  # confronte désormais chaque option longue à « wget --help ».
  if (cd "$rep" && wget -q -r -l 3 -np -k -p -E --restrict-file-names=windows \
        --quota="$plafond" --timeout=20 --tries=2 --user-agent="$ua" \
        --reject "*.iso,*.zip,*.exe,*.7z,*.img,*.tar.gz,*.deb,*.rpm,*.dd,*.gz,*.xz,*.bz2,*.dmg,*.msi,*.vdi,*.ova,*.qcow2,*.mp4,*.webm" \
        --reject-regex "\.(dd|img|iso)(\.|$)" \
        "$url" 2>/dev/null); then
    :
  fi
  # UN MIROIR MAIGRE N'EST PAS UN SUCCÈS.
  #
  # Un miroir d'une ou deux pages est compté « réussi » et présenté comme un
  # manuel dans l'index. Or un manuel d'une page qui prétend documenter un
  # système entier est PLUS dangereux qu'un manuel absent : on ne cherchera pas
  # ailleurs le jour où l'on en a besoin.
  #
  # LE CONTENU JUGE, PAS LE NOMBRE DE PAGES — et c'est contre-intuitif : certains
  # manuels tiennent en UNE page de plus d'un mégaoctet, avec des centaines de
  # liens internes, et pèsent des dizaines de mégaoctets avec leurs ressources.
  # Une règle « moins de cinq pages » les déclarerait inexploitables alors qu'ils
  # sont complets.
  #
  # On exige donc les deux : peu de pages ET peu de contenu. Les vraies coquilles
  # vides sont sans ambiguïté — Fedora 1 page / 24 Ko, Ubuntu 1 page / 116 Ko —
  # là où un manuel en page unique se compte en mégaoctets.
  # LA PORTE D'ENTRÉE, DÉSIGNÉE ET NON DEVINÉE.
  #
  # L'index cherchait « le premier index.html trouvé », dans l'ordre du système
  # de fichiers. Pour Ubuntu Server il tombait sur
  # « documentation.ubuntu.com/server/index.html » — la page unique rapportée
  # AVANT le correctif de redirection, dont TOUS les liens sont absolus. On
  # ouvrait le manuel hors ligne et le premier clic partait sur Internet, ce qui
  # est exactement ce que ce dépôt existe pour éviter. Les 255 vraies pages,
  # elles, étaient là, sous l'adresse vers laquelle le site redirige.
  #
  # On écrit donc la porte d'entrée au moment où on la connaît : c'est l'URL
  # d'où le miroir est parti, traduite en chemin local. Même principe que le
  # « .chemin » du coffre de binaires — la vérité est notée par qui la sait.
  entree_manuel "$rep" "$depart"

  # UN MANUEL NE PÈSE PAS 760 Mo — ET LES LISTES DE REJET NE SUFFISENT PAS.
  #
  # On croit volontiers qu'un rejet par expression attrape les extensions
  # composées et qu'il suffit. C'est faux : une image disque de 760 Mo nommée
  # « ….dd.html.gz » revient sous un plafond de 60 Mo, malgré « *.gz » dans la
  # liste ET « \.dd\. » dans l'expression. wget télécharge d'abord ce qu'il prend
  # pour du HTML — et un tel nom lui en a tout l'air — puis n'applique plus rien.
  #
  # On cesse donc d'essayer de l'en empêcher, et on nettoie APRÈS : dans un
  # miroir de documentation, un fichier de cette taille n'est pas de la
  # documentation. C'est aussi ce qui rend le poids affiché honnête — CAINE
  # était annoncé « 40 pages, 738M », dont 738 Mo d'image disque.
  local gros
  while IFS= read -r gros; do
    [ -n "$gros" ] || continue
    info "  écarté du manuel : $(basename "$gros") ($(du -h "$gros" 2>/dev/null | cut -f1))"
    rm -f "$gros" 2>/dev/null || true
  done < <(find "$rep" -type f -size +"${PRA_DOC_FICHIER_MAX_MO:-50}"M 2>/dev/null)

  local seuil="${PRA_DOC_SEUIL:-5}"
  local seuil_ko="${PRA_DOC_SEUIL_KO:-2048}"
  local n; n="$(find "$rep" -name '*.html' 2>/dev/null | wc -l)"
  n="${n// /}"
  local ko; ko="$(du -sk "$rep" 2>/dev/null | cut -f1)"; ko="${ko:-0}"
  if [ "$n" -eq 0 ]; then
    mal "$libelle — aucune page récupérée"
    return 1
  fi
  if [ "$n" -lt "$seuil" ] && [ "$ko" -lt "$seuil_ko" ]; then
    mal "$libelle — $n page(s) seulement : miroir INEXPLOITABLE"
    info "  navigation en JavaScript ou plan du site absent — à consulter en ligne"
    # Trace sur place : celui qui ouvrira le dossier hors ligne doit comprendre
    # pourquoi il est presque vide, sans avoir à retrouver ce journal.
    printf 'MIROIR INCOMPLET\n\n%s pages seulement ont pu être copiées depuis :\n  %s\n\nLa navigation de ce site est construite en JavaScript, ou son plan du site\nest absent : wget ne trouve pas les liens à suivre.\n\nCe dossier NE REMPLACE PAS la documentation en ligne. Ne vous y fiez pas\nen situation de crise sans avoir vérifié qu%s il contient ce qu%s il vous faut.\n' \
      "$n" "$url" "'" "'" > "$rep/LISEZ-MOI-INCOMPLET.txt" 2>/dev/null || true
    return 1
  fi
  ok "$libelle — $n pages, $(du -sh "$rep" 2>/dev/null | cut -f1)"
}

# Une page d'accueil pour les manuels : sans elle, on se retrouve devant une
# arborescence de répertoires sans savoir par où entrer.
index_documentation() {
  local f="$DOC/index.html"
  {
    cat <<'ENTETE'
<!doctype html><html lang="fr"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Manuels hors ligne — Arche</title>
<style>
:root{--bg:#0d1013;--surf:#151b21;--hair:rgba(255,255,255,.09);
  --txt:#eef2f6;--dim:#93a0ad;--acc:#4fc3b0}
@media(prefers-color-scheme:light){:root{--bg:#f6f7f9;--surf:#fff;
  --hair:rgba(0,0,0,.1);--txt:#12171c;--dim:#5c6773;--acc:#127f6e}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--txt);
  font:16px/1.6 ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
.wrap{max-width:52rem;margin:0 auto;padding:2.5rem 1.5rem 5rem}
h1{font-size:1.7rem;margin:0 0 .3rem;letter-spacing:-.02em}
h1 em{color:var(--acc);font-style:normal}
.sous{color:var(--dim);margin-bottom:2rem}
h2{font-size:1.05rem;margin:2.2rem 0 .7rem;letter-spacing:-.01em}
h2::before{content:"";display:inline-block;width:1.5rem;height:.14rem;
  background:var(--acc);vertical-align:.35em;margin-right:.7rem;border-radius:.1rem}
ul{list-style:none;padding:0;margin:0}
li{background:var(--surf);border:1px solid var(--hair);border-radius:.8rem;
  padding:.9rem 1.1rem;margin:.5rem 0}
li a{color:var(--acc);text-decoration:none;font-weight:600;font-size:1.05rem}
li a:hover{text-decoration:underline}
li .q{display:block;color:var(--dim);font-size:.92rem;margin-top:.2rem}
li.absent{opacity:.55} li.absent b{font-weight:600}
footer{margin-top:3rem;padding-top:1.2rem;border-top:1px solid var(--hair);
  color:var(--dim);font-size:.87rem}
@media print{:root{--bg:#fff;--surf:#fff;--txt:#000;--dim:#444;--acc:#000;--hair:#bbb}}
</style></head><body>
<!-- La porte de retour : sans elle, l'index des manuels est un cul-de-sac
     depuis lequel il faut connaître l'adresse de l'accueil pour en sortir. -->
<div style="font:14px/1.4 ui-sans-serif,system-ui,-apple-system,sans-serif;
  background:var(--surf);border-bottom:1px solid var(--hair);padding:.55rem 1.5rem">
  <a href="../" style="color:var(--acc);text-decoration:none">&#8592; Accueil</a>
</div>
<div class="wrap">
<h1>Manuels <em>hors ligne</em></h1>
<div class="sous">Les documentations des outils du dépôt, copiées pour être lues
sans Internet — c'est-à-dire le jour où elles servent.</div>
ENTETE

    # On parcourt les catégories dans l'ordre du catalogue, sans les trier :
    # cet ordre est celui du déroulé d'une crise — constater, réparer,
    # reconstruire. Le trier alphabétiquement le détruirait.
    # LES DEUX CATALOGUES DANS LE MÊME INDEX.
    #
    # Les sources git n'y figuraient pas du tout : 275 fichiers de documentation
    # Raspberry Pi et 282 de Fedora, sur le disque, sans rien qui y mène. Depuis
    # que ces deux sites refusent les automates, la source est leur SEULE
    # documentation — les omettre revient à les faire disparaître du dépôt.
    #
    # Les deux tableaux partagent le même format en six champs, dont la
    # catégorie en cinquième position : on peut donc les fusionner et regrouper
    # par catégorie, en gardant l'ordre du catalogue — constater, réparer,
    # reconstruire.
    local -a toutes=("${DOCUMENTATIONS[@]}" "${DOCS_GIT[@]}")
    local -a cats=()
    local c
    local x vu
    for entree in "${toutes[@]}"; do
      IFS='|' read -r _ _ _ _ c _ <<<"$entree"
      vu=0
      for x in "${cats[@]:-}"; do [ "$x" = "$c" ] && { vu=1; break; }; done
      [ "$vu" = 1 ] || cats+=("$c")
    done
    # LE BANDEAU SUR TOUS LES MANUELS, AVANT DE LES LISTER.
    #
    # C'est ici qu'on dispose des deux catalogues et de leurs libellés — les
    # recalculer ailleurs les ferait diverger le jour où l'un des deux change.
    local _pose _total=0
    for entree in "${toutes[@]}"; do
      IFS='|' read -r lib dos _ _ _ _ <<<"$entree"
      [ -d "$DOC/$dos" ] || continue
      _pose="$(bandeaux_partout "$DOC/$dos" "$lib")"
      _total=$(( _total + ${_pose:-0} ))
    done
    [ "$_total" -gt 0 ] && info "  bandeau posé sur $_total page(s)"

    for c in "${cats[@]}"; do
    printf '<h2>%s</h2><ul>' "$c"
    for entree in "${toutes[@]}"; do
      IFS='|' read -r lib dos _ _ cat usage <<<"$entree"
      [ "$cat" = "$c" ] || continue
      # LA PORTE D'ENTRÉE ÉCRITE PAR LE MIROIR, sinon la moins profonde.
      # « le premier index.html trouvé » dépendait de l'ordre du système de
      # fichiers : pour Ubuntu Server, il désignait une page morte de la veille
      # dont tous les liens partaient sur Internet. À défaut de « .entree », on
      # prend au moins la page la PLUS PROCHE DE LA RACINE — une racine de
      # manuel est rarement enfouie.
      local cible="" _motif
      if [ -s "$DOC/$dos/.entree" ]; then
        local e; e="$(head -1 "$DOC/$dos/.entree" 2>/dev/null)"
        [ -n "$e" ] && [ -f "$DOC/$dos/$e" ] && cible="$dos/$e"
      fi
      # « | head -1 » ferme le tuyau dès la première ligne : « sort » écrit
      # alors dans un tuyau rompu et crache « write error: Broken pipe » sur la
      # sortie d'erreur — neuf lignes de bruit par exécution, dans le journal
      # que l'exploitant lit. Même faute que le « grep -c || echo 0 » corrigé ce
      # matin, commise en la corrigeant. On prend donc la première ligne en
      # shell pur, sans tuyau.
      local _liste _premier
      for _motif in 'index.html' '*.html'; do
        [ -n "$cible" ] && break
        _liste="$(cd "$DOC" 2>/dev/null && find "$dos" -name "$_motif" -printf '%d %p\n' 2>/dev/null | sort -n || true)"
        [ -n "$_liste" ] || continue
        _premier="${_liste%%$'\n'*}"
        cible="${_premier#* }"
      done
      if [ -n "$cible" ]; then
        printf '<li><a href="%s">%s</a><span class="q">%s</span></li>' \
               "$cible" "$lib" "$usage"
      else
        printf '<li class="absent"><b>%s</b><span class="q">%s — non récupéré</span></li>' \
               "$lib" "$usage"
      fi
    done
    printf '</ul>'
    done

    printf '<footer>Copie du %s. ' "$(date '+%d/%m/%Y')"
    printf 'Le navigateur cherche dans une page à la fois : commencez par choisir '
    printf 'le manuel ci-dessus, puis cherchez dedans.</footer>'
    printf '</div></body></html>'
  } > "$f"
  chmod 644 "$f"
}

telecharger() {          # $1 url  $2 destination
  local url="$1"
  local dest="$2"
  local args=(-fL --retry 3 --retry-delay 5 -C - -o "$dest")
  [ -n "$LIMITE" ] && args+=(--limit-rate "$LIMITE")
  # La barre de progression écrit avec des retours chariot : utile devant un
  # terminal, illisible dans un journal, où elle produit des lignes de plusieurs
  # milliers de caractères. On la réserve donc au cas interactif.
  if [ -t 1 ]; then args+=(--progress-bar); else args+=(-s -S); fi
  curl "${args[@]}" "$url"
}

traiter() {
  local libelle="$1" dossier="$2" base="$3" fsommes="$4" motif="$5"
  local rep="$ISO/$dossier"
  # LES ARCHIVES KIWIX VONT LÀ OÙ KIWIX LES LIT, PAS DANS LE DÉPÔT.
  #
  # Elles étaient téléchargées dans « iso/kiwix », puis déplacées À LA MAIN vers
  # /home/yunohost.app/kiwix pour que kiwix-serve les trouve. Conséquence : le
  # script ne les voyait plus à leur place et RETÉLÉCHARGEAIT 21 Go à chaque
  # passage : le répertoire de téléchargement reste vide à quelques kilo-octets,
  # et la mise à jour reprend des archives déjà présentes ailleurs.
  #
  # Le dossier de destination est donc celui de kiwix-serve, et la déclaration
  # dans la bibliothèque se fait juste après le téléchargement. Plus rien à
  # déplacer, donc plus rien à oublier de déplacer.
  [ "$dossier" = "kiwix" ] && rep="$KIWIX"
  mkdir -p "$rep"

  local nom attendue

  # SIDECAR : l'URL du fichier est donnée telle quelle (elle peut rediriger vers
  # la version courante), et sa somme vit à côté, en « .sha256 ». C'est le cas
  # des URL « latest » de NixOS et de Raspberry Pi OS.
  if [ "$base" = "SIDECAR" ]; then
    local url="$fsommes" reel
    reel="$(curl -fsL --max-time 45 -o /dev/null -w '%{url_effective}' "$url" 2>/dev/null)"
    [ -n "$reel" ] || { mal "$libelle — URL irrésolue"; return 1; }
    attendue="$(curl -fsL --max-time 45 "$url.sha256" 2>/dev/null | awk '{print $1; exit}' || true)"
    [ -n "$attendue" ] || { mal "$libelle — somme absente"; return 1; }
    _telecharger_et_verifier "$libelle" "$rep/${reel##*/}" "$reel" "$attendue"
    return $?
  fi

  # GITHUB : on interroge l'API pour la dernière publication et on y choisit le
  # fichier par motif. Aucune somme n'est publiée de façon exploitable — ces
  # fichiers sont donc récupérés SANS vérification, et le manifeste le dit.
  if [ "$base" = "GITHUB" ]; then
    local depot="$fsommes" url
    url="$(curl -fsL --max-time 45 "https://api.github.com/repos/$depot/releases/latest" 2>/dev/null \
           | python3 -c "
import json, re, sys
try: d = json.load(sys.stdin)
except ValueError: sys.exit()
m = re.compile(sys.argv[1])
for a in d.get('assets', []):
    if m.match(a.get('name', '')):
        print(a['browser_download_url']); break
" "$motif" 2>/dev/null)"
    [ -n "$url" ] || { mal "$libelle — aucun fichier ne correspond dans $depot"; return 1; }
    local nomf="${url##*/}" dest="$OUTILS"
    [ "$dossier" = "statiques" ] && dest="$OUTILS/statiques"
    [ "$dossier" = "forensic" ] && dest="$ISO/forensic"
    mkdir -p "$dest"
    if [ -s "$dest/$nomf" ]; then ok "$libelle — déjà présent"; return 0; fi
    bleu "$libelle → $nomf"
    telecharger "$url" "$dest/$nomf" || { mal "$libelle — échec"; return 1; }
    chmod +x "$dest/$nomf" 2>/dev/null || true
    ok "$libelle — récupéré (somme non publiée : à vérifier à la main)"
    return 0
  fi

  # INDEXNV : même découverte par index, mais AUCUNE somme n'est publiée par le
  # projet. Le fichier est récupéré et signalé comme non vérifié dans le
  # manifeste. C'est un choix assumé : mieux vaut disposer d'une image
  # d'investigation non vérifiée que de ne pas en avoir du tout, à condition que
  # le manifeste le dise et que personne ne s'y trompe.
  if [ "$fsommes" = "INDEXNV" ]; then
    nom="$(curl -fsL --max-time 90 "$base/" 2>/dev/null \
           | grep -oE "$motif" | sort -uV | tail -1 || true)"
    [ -n "$nom" ] || { mal "$libelle — rien de tel dans l'index"; return 1; }
    if [ -s "$rep/$nom" ]; then ok "$libelle — déjà présent"; return 0; fi
    bleu "$libelle → $nom"
    telecharger "$base/$nom" "$rep/$nom" || { mal "$libelle — échec"; return 1; }
    ok "$libelle — récupéré (somme non publiée : à vérifier à la main)"
    return 0
  fi

  if [ "$fsommes" = "INDEX" ]; then
    # On lit l'index du répertoire et on retient la plus récente : les noms
    # portent leur date (AAAA-MM), l'ordre alphabétique donne donc le dernier.
    nom="$(curl -fsL --max-time 90 "$base/" 2>/dev/null \
           | grep -oE "$motif" | sort -u | tail -1 || true)"
    [ -n "$nom" ] || { mal "$libelle — rien de tel dans l'index"; return 1; }
    attendue="$(curl -fsL --max-time 45 "$base/$nom.sha256" 2>/dev/null \
                | awk '{print $1; exit}' || true)"
    [ -n "$attendue" ] || { mal "$libelle — somme absente pour $nom"; return 1; }
    _telecharger_et_verifier "$libelle" "$rep/$nom" "$base/$nom" "$attendue"
    return $?
  fi

  # Un « ~ » en tête signifie que le nom du fichier de sommes porte lui-même le
  # numéro de version : on le retrouve dans l'index plutôt que de le figer.
  local fs="$fsommes"
  if [ "${fs:0:1}" = "~" ]; then
    fs="$(curl -fsL --max-time 60 "$base/" 2>/dev/null \
          | grep -oE "${fs:1}" | sort -u | tail -1 || true)"
    [ -n "$fs" ] || { mal "$libelle — fichier de sommes introuvable dans l'index"; return 1; }
  fi

  local brut
  brut="$(curl -fsL --max-time 60 "$base/$fs" 2>/dev/null)" || {
    mal "$libelle — fichier de sommes injoignable ($base/$fs)"; return 1; }

  # Deux formats coexistent dans la nature, et s'y tromper fait échouer la
  # découverte sans rien dire d'utile :
  #   GNU  « somme  fichier »
  #   BSD  « SHA256 (fichier) = somme »   — Rocky et AlmaLinux
  # On normalise tout en « somme fichier » avant d'aller plus loin.
  local sommes
  sommes="$(printf '%s\n' "$brut" | awk '
    /^SHA256 \(/ { nom = $2; gsub(/[()]/, "", nom); print $4, nom; next }
    NF >= 2 && $1 ~ /^[0-9a-fA-F]{64}$/ { nom = $NF; gsub(/^\*/, "", nom);
                                          print $1, nom }')"
  [ -n "$sommes" ] || { mal "$libelle — fichier de sommes illisible"; return 1; }

  # Le nom de fichier courant, découvert dans le fichier de sommes.
  # « sort -V | tail -1 » et non « head -1 » : quand un projet publie plusieurs
  # versions correctives dans le même index — cdimage d'Ubuntu liste 24.04.3 ET
  # 24.04.4 — la première rencontrée n'est pas la plus récente. On récupérerait
  # une version dépassée sans que rien ne le signale.
  nom="$(printf '%s\n' "$sommes" | awk '{print $2}' | grep -E "$motif" | sort -uV | tail -1 || true)"
  [ -n "$nom" ] || { mal "$libelle — aucun fichier ne correspond au motif"; return 1; }

  attendue="$(printf '%s\n' "$sommes" | awk -v n="$nom" '$2 == n {print $1; exit}')"
  [ -n "$attendue" ] || { mal "$libelle — somme absente pour $nom"; return 1; }

  _telecharger_et_verifier "$libelle" "$rep/$nom" "$base/$nom" "$attendue"
}

_telecharger_et_verifier() {   # $1 libellé  $2 cible  $3 url  $4 somme attendue
  local libelle="$1" cible="$2" url="$3" attendue="$4" reelle

  if [ -f "$cible" ]; then
    reelle="$(sha256sum "$cible" | awk '{print $1}')"
    if [ "$reelle" = "$attendue" ]; then ok "$libelle — déjà présent et vérifié"; return 0; fi
    info "présent mais incomplet ou altéré : reprise"
  fi

  bleu "$libelle → $(basename "$cible")"
  telecharger "$url" "$cible" || { mal "$libelle — téléchargement en échec"; return 1; }

  reelle="$(sha256sum "$cible" | awk '{print $1}')"
  if [ "$reelle" != "$attendue" ]; then
    # La cause la PLUS FRÉQUENTE n'est pas une image falsifiée mais une reprise
    # ratée : « curl -C - » repart de la taille du fichier local, et si le
    # serveur ignore l'en-tête Range — ou si la reprise part d'un point erroné
    # après une exécution interrompue — les octets se dupliquent. Le fichier est
    # alors PLUS GROS que l'original, ce qui se voit.
    #
    # Écarter et passer laisserait un dépôt incomplet pour une cause qu'un
    # retéléchargement propre corrige. On réessaie donc UNE fois, depuis zéro.
    warn "$libelle — somme incorrecte, nouvelle tentative depuis zéro"
    info "  attendue $attendue"
    info "  obtenue  $reelle"
    rm -f "$cible"
    telecharger "$url" "$cible" || { mal "$libelle — téléchargement en échec"; return 1; }
    reelle="$(sha256sum "$cible" | awk '{print $1}')"
  fi

  if [ "$reelle" != "$attendue" ]; then
    # Deux échecs de suite, dont un sur un téléchargement complet : ce n'est
    # plus une reprise ratée. Le fichier est écarté sans être supprimé — il peut
    # servir à comprendre — et le manifeste ne le compte pas.
    mal "$libelle — SOMME INCORRECTE APRÈS DEUX TENTATIVES, fichier écarté"
    info "  attendue $attendue"
    info "  obtenue  $reelle"
    mv -f "$cible" "$cible.SUSPECT"
    return 1
  fi
  ok "$libelle — vérifié"
}

manifeste() {
  {
    echo "MANIFESTE DU DÉPÔT DE SECOURS"
    echo "Généré le $(date '+%d/%m/%Y à %H:%M')"
    echo
    echo "Chaque image a été contrôlée contre la somme SHA-256 publiée par son"
    echo "projet, récupérée en HTTPS. Les fichiers marqués « non vérifié » ont été"
    echo "déposés à la main : contrôlez-les avant de vous en servir."
    echo
    printf '%-12s %-52s %s\n' "TAILLE" "FICHIER" "SHA-256 (12 premiers)"
    echo "───────────────────────────────────────────────────────────────────────────"
    find "$ISO" "$OUTILS" -type f ! -name '*.SUSPECT' 2>/dev/null | sort | while read -r f; do
      printf '%-12s %-52s %s\n' "$(du -h "$f" | cut -f1)" \
             "${f#"$DEPOT"/}" "$(sha256sum "$f" | cut -c1-12)"
    done
    echo
    if [ -d "$DOC" ]; then
      echo "DOCUMENTATION HORS LIGNE"
      for d in "$DOC"/*/; do
        [ -d "$d" ] || continue
        printf '%-12s %-52s %s pages\n' "$(du -sh "$d" | cut -f1)" \
               "${d#"$DEPOT"/}" "$(find "$d" -name '*.html' | wc -l)"
      done
      echo "  Point d'entrée : documentation/index.html"
      echo
    fi
    echo "Place restante : $(df -h "$DEPOT" | awk 'NR>1{print $4}')"
  } > "$MANIFESTE"
  chmod 644 "$MANIFESTE"
}

# ── Répertoires que le script ne peut pas remplir seul ──────────────────────
# Un répertoire PAR LOGICIEL, avec sa notice et son fichier de sommes vide.
# Tout déposer en vrac dans « forensic/ » revient à ne pas savoir, six mois plus
# tard, quelle image attend quelle somme — ni même laquelle a été vérifiée.
_dossier_manuel() {      # $1 chemin  $2 titre  $3 où le prendre  $4 notes
  mkdir -p "$1"
  cat > "$1/LISEZ-MOI.txt" <<FIN
$2
$(printf '=%.0s' $(seq 1 ${#2}))

À DÉPOSER ICI, à la main.

  Où :   $3

$4

APRÈS DÉPÔT, notez la somme SHA-256 publiée par le projet dans le fichier
« sommes.txt » de ce répertoire, au format :

  <somme>  <nom du fichier>

Sans elle, personne ne pourra vérifier l'image le jour où elle servira — et
c'est le seul jour où l'on ne pourra plus le faire.

Pour contrôler après coup :  sha256sum -c sommes.txt
FIN
  [ -f "$1/sommes.txt" ] || {
    printf '# <somme sha256>  <nom du fichier>\n' > "$1/sommes.txt"
  }
}

preparer_manuels() {
  mkdir -p "$ISO/windows" "$ISO/redhat"

  cat > "$ISO/windows/LISEZ-MOI.txt" <<'FIN'
WINDOWS — À DÉPOSER À LA MAIN
=============================

Microsoft ne publie pas d'URL stable : le lien de téléchargement est généré
pour votre session et expire. Aucun script ne peut donc le récupérer.

Marche à suivre, depuis un poste :

  1. Windows 11 et 10 — page « Télécharger une image disque (ISO) » de
     Microsoft. Choisir l'édition multi-langue, puis le français.
  2. Windows Server — « Évaluations » sur le centre d'évaluation Microsoft.
     Version d'évaluation de 180 jours, suffisante pour reconstruire et
     réactiver ensuite avec vos licences.
  3. Déposer les fichiers ICI, par l'interface du dépôt.
  4. Noter la somme SHA-256 affichée par Microsoft dans un fichier
     « sommes.txt » à côté — sans quoi personne ne pourra vérifier l'image
     le jour où elle servira.

LICENCE : ces supports sont des images d'installation ou d'évaluation. Le
droit d'utilisation reste porté par vos licences existantes, qui ne sont pas
dans ce dépôt. Pensez à conserver les clés ailleurs.
FIN

  cat > "$ISO/redhat/LISEZ-MOI.txt" <<'FIN'
RED HAT ENTERPRISE LINUX — À DÉPOSER À LA MAIN
==============================================

Le téléchargement de RHEL exige un compte Red Hat et un abonnement, même pour
la version « Developer » gratuite. Aucun script ne peut s'authentifier à votre
place.

Si vous avez des machines sous RHEL :

  1. Se connecter au portail client Red Hat, section Téléchargements.
  2. Prendre l'ISO « Binary DVD » de la version en service chez vous.
  3. Déposer le fichier ici, avec la somme SHA-256 affichée par Red Hat dans
     un fichier « sommes.txt ».

SI VOUS N'EN AVEZ PAS BESOIN : Rocky Linux et AlmaLinux, déjà présents dans ce
répertoire, sont des reconstructions binairement compatibles de RHEL. Pour
reconstruire un serveur, ils font le même travail.
FIN

  mkdir -p "$DEPOT/anssi" "$ISO/forensic" "$ISO/secours" "$OUTILS/statiques"

  cat > "$OUTILS/statiques/LISEZ-MOI.txt" <<'FIN'
BINAIRES STATIQUES — POURQUOI ILS SONT LÀ
=========================================

Sur une machine compromise, ON NE FAIT PAS CONFIANCE AUX BINAIRES LOCAUX.

Un « ls » modifié cache les fichiers de l'attaquant. Un « ps » modifié cache
ses processus. Un « netstat » modifié cache ses connexions. C'est exactement ce
que fait un rootkit, et rien ne le laisse voir : les commandes répondent
normalement, elles mentent simplement.

Ces exécutables sont liés STATIQUEMENT : ils n'appellent aucune bibliothèque de
la machine examinée. Copiés depuis une clé, ils donnent une vue non truquée.

USAGE :

  1. Copier le fichier sur une clé USB, JAMAIS sur la machine examinée.
  2. L'exécuter depuis la clé, en chemin absolu :
         /media/cle/busybox-x86_64 ps
         /media/cle/busybox-x86_64 netstat -anp
         /media/cle/busybox-x86_64 ls -la /tmp
  3. Comparer avec ce que répondent les commandes locales. Un écart EST le
     résultat : il désigne ce qu'on vous cache.

busybox réunit une centaine de commandes en un seul fichier — ls, ps, netstat,
find, grep, dd, md5sum. C'est ce qu'on emporte quand on ne sait pas encore ce
qu'on cherche.

À COMPLÉTER à la main si vous voulez aller plus loin : des versions statiques de
tcpdump, nmap, strace et lsof se trouvent sur le même dépôt GitHub
(ryanwoodsmall/static-binaries) et ailleurs. Notez leurs sommes.
FIN


  cat > "$DEPOT/anssi/LISEZ-MOI.txt" <<'FIN'
GUIDES DE L'ANSSI — À DÉPOSER À LA MAIN
=======================================

cyber.gouv.fr construit sa page de publications en JavaScript : aucun lien PDF
n'apparaît dans le HTML servi, et aucun script ne peut donc les récupérer.

À télécharger depuis cyber.gouv.fr, rubrique Publications, et à déposer ici :

  - « Crise d'origine cyber, les clés d'une gestion opérationnelle et
    stratégique » — le plus utile de tous le jour venu.
  - « Anticiper et gérer sa communication de crise cyber ».
  - Guide d'hygiène informatique.
  - Guide de remédiation (les trois volets : pilotage, opérationnel,
    technique).
  - Les recommandations de durcissement qui concernent vos systèmes :
    Active Directory, OpenSSH, TLS, journalisation.

Quelques dizaines de mégaoctets pour ce qui cadrera vos décisions en crise.
C'est votre référentiel métier : il doit être ici, pas seulement dans un
navigateur.
FIN

  cat > "$ISO/forensic/LISEZ-MOI.txt" <<'FIN'
INVESTIGATION — CE QUI EST AUTOMATIQUE, ET CE QUI NE L'EST PAS
==============================================================

AUTOMATIQUE : Kali Linux Live, téléchargé et vérifié par pra_depot_isos.sh.
Son mode « Live (forensic) » ne monte aucun disque et n'active pas le swap :
c'est ce qu'il faut pour regarder sans rien modifier.

À DÉPOSER À LA MAIN — ces projets ne publient pas de somme de contrôle à une
URL stable, et un téléchargement non vérifié n'a pas sa place ici sans que
quelqu'un l'ait contrôlé :

  - Tsurugi     (tsurugi-linux.org)  ~5 Go, très complète, orientée analyse.
                                     Sa page de téléchargement ne publie aucun
                                     lien direct : elle passe par une sélection
                                     de miroir qu'aucun script ne peut suivre.

  - Memtest86+  (memtest.org)        quelques mégaoctets. Ses publications
                                     GitHub ne portent aucun fichier, et son
                                     site ne donne pas d'URL stable.

Notez leur somme SHA-256 dans un fichier « sommes.txt » à côté, sinon personne
ne pourra les vérifier le jour où elles serviront.

DÉJÀ RÉCUPÉRÉS AUTOMATIQUEMENT, mais NON VÉRIFIÉS — leurs projets ne publient
pas de somme à une adresse stable. Contrôlez-les avant de vous en servir :

  - CAINE, depuis le miroir d'Aix-la-Chapelle que le projet met en avant.
  - DFIR ORC, le collecteur d'artefacts de l'ANSSI. Il ne s'installe pas : on
    le pose sur une machine Windows suspecte, il collecte et rend une archive.
    C'est l'outil à passer AVANT toute réparation — réparer détruit les traces
    qu'on cherchera ensuite.

LE RÉFLEXE QUI COMPTE : avant toute réparation, faire une copie bit à bit du
disque et travailler sur la copie. Réparer détruit les traces, et on ne sait
qu'après coup qu'on en aurait eu besoin.
FIN

  cat > "$ISO/secours/LISEZ-MOI.txt" <<'FIN'
SECOURS — CE QUI EST AUTOMATIQUE, ET CE QUI NE L'EST PAS
========================================================

AUTOMATIQUE : SystemRescue, téléchargé et vérifié. Il couvre l'essentiel —
monter un système qui ne démarre plus, réparer une table de partitions,
remettre un GRUB, récupérer des fichiers.

À DÉPOSER À LA MAIN, si vous en voulez plus :

  - Memtest86+        (memtest.org)     test mémoire, quelques mégaoctets.
                                        Ses publications GitHub ne portent
                                        aucun fichier et son site ne donne pas
                                        d'URL stable.

DÉJÀ RÉCUPÉRÉS AUTOMATIQUEMENT :

  - Clonezilla, vérifié contre la somme publiée par le projet.
  - GParted Live et Hiren's BootCD PE, récupérés mais NON VÉRIFIÉS : leurs
    sommes ne sont affichées que sur une page web. Contrôlez-les avant usage,
    et notez le résultat dans « sommes.txt ».
FIN

  # Un sous-dossier par logiciel restant à déposer.
  _dossier_manuel "$ISO/forensic/tsurugi" "TSURUGI LINUX" \
    "tsurugi-linux.org, section Downloads" \
    "Distribution d'investigation très complète, environ 5 Go.
Sa page ne publie aucun lien direct : elle passe par une sélection de miroir
qu'aucun script ne peut suivre. C'est la raison pour laquelle elle est ici et
non récupérée automatiquement."

  _dossier_manuel "$ISO/secours/memtest86plus" "MEMTEST86+" \
    "memtest.org" \
    "Test de mémoire amorçable, quelques mégaoctets.
Ses publications GitHub ne portent aucun fichier et son site ne donne pas
d'URL stable — d'où le dépôt à la main."

  _dossier_manuel "$ISO/secours/hirens" "HIREN'S BOOTCD PE" \
    "hirensbootcd.org" \
    "Environnement Windows de récupération, environ 3 Go.
Récupéré automatiquement s'il est absent, mais SANS vérification : sa somme
n'est publiée que sur une page web. Contrôlez-la et notez-la ici."

  _dossier_manuel "$ISO/windows/windows-11" "WINDOWS 11" \
    "Microsoft, page « Télécharger une image disque (ISO) »" \
    "Choisir l'édition multi-langue, puis le français.
Le lien est généré pour votre session et expire : aucun script ne peut le
suivre. Notez la somme affichée par Microsoft."

  _dossier_manuel "$ISO/windows/windows-10" "WINDOWS 10" \
    "Microsoft, même page" \
    "Utile pour du matériel que Windows 11 refuse."

  _dossier_manuel "$ISO/windows/windows-server" "WINDOWS SERVER" \
    "Centre d'évaluation Microsoft" \
    "Version d'évaluation de 180 jours, suffisante pour reconstruire et
réactiver ensuite avec vos licences."

  _dossier_manuel "$ISO/redhat/rhel" "RED HAT ENTERPRISE LINUX" \
    "Portail client Red Hat, section Téléchargements" \
    "Exige un compte Red Hat et un abonnement, même pour la version
« Developer » gratuite. Prendre l'ISO « Binary DVD » de la version en service.

SI VOUS N'EN AVEZ PAS BESOIN : Rocky Linux et AlmaLinux, déjà présents et
vérifiés, sont des reconstructions binairement compatibles de RHEL."

  _dossier_manuel "$DEPOT/anssi/guides" "GUIDES DE L'ANSSI" \
    "cyber.gouv.fr, rubrique Publications" \
    "cyber.gouv.fr construit sa page en JavaScript : aucun lien PDF n'apparaît
dans le HTML servi.

À prendre en priorité :
  - « Crise d'origine cyber, les clés d'une gestion opérationnelle et
    stratégique » — le plus utile de tous le jour venu ;
  - « Anticiper et gérer sa communication de crise cyber » ;
  - le guide d'hygiène informatique ;
  - les trois volets du guide de remédiation."

  ok "répertoires préparés, un par logiciel à déposer"
}

# Compare ce qui est sur le disque à ce que les projets publient AUJOURD'HUI,
# sans rien télécharger. C'est ce qui permet de décider s'il vaut la peine de
# lancer plusieurs heures de transfert.
verifier() {
  bleu "Comparaison avec les versions publiées (aucun téléchargement)"
  echo
  local a_jour=0 obsoletes=0 absents=0
  for entree in "${CATALOGUE[@]}"; do
    IFS='|' read -r libelle dossier base fsommes motif <<<"$entree"
    local nom=""
    if [ "$fsommes" = "INDEX" ]; then
      nom="$(curl -fsL --max-time 90 "$base/" 2>/dev/null | grep -oE "$motif" | sort -u | tail -1 || true)"
    else
      nom="$(curl -fsL --max-time 60 "$base/$fsommes" 2>/dev/null | awk '
        /^SHA256 \(/ { n = $2; gsub(/[()]/, "", n); print n; next }
        NF >= 2 && $1 ~ /^[0-9a-fA-F]{64}$/ { n = $NF; gsub(/^\*/, "", n); print n }' \
        | grep -E "$motif" | head -1 || true)"
    fi
    if [ -z "$nom" ]; then
      printf '  %-30s %s\n' "$libelle" "source injoignable"; continue
    fi
    if [ -f "$ISO/$dossier/$nom" ]; then
      printf '  %-30s à jour (%s)\n' "$libelle" "$nom"; a_jour=$((a_jour + 1))
    elif compgen -G "$ISO/$dossier/*" >/dev/null 2>&1 \
         && [ -n "$(find "$ISO/$dossier" -maxdepth 1 -type f ! -name '*.txt' -print -quit 2>/dev/null)" ]; then
      printf '  %-30s NOUVELLE VERSION : %s\n' "$libelle" "$nom"; obsoletes=$((obsoletes + 1))
    else
      printf '  %-30s absent : %s\n' "$libelle" "$nom"; absents=$((absents + 1))
    fi
  done
  echo
  bleu "$a_jour à jour, $obsoletes à renouveler, $absents absents"
  [ "$obsoletes" -gt 0 ] || [ "$absents" -gt 0 ] \
    && info "lancez « pra_depot_isos.sh » pour combler, puis « --nettoyer »"
  return 0
}

# Retire les versions périmées. Sans cela le dépôt grossit indéfiniment : chaque
# nouvelle version arrive sous un nom différent et l'ancienne reste à côté, sans
# que personne sache laquelle est la bonne.
nettoyer() {
  local supprimes=0
  bleu "Recherche des versions périmées"
  for entree in "${CATALOGUE[@]}"; do
    IFS='|' read -r libelle dossier base fsommes motif <<<"$entree"
    local rep="$ISO/$dossier"
    [ -d "$rep" ] || continue
    # Toutes les versions présentes correspondant à ce motif, la plus récente
    # en dernier. On ne garde que celle-là.
    mapfile -t versions < <(find "$rep" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null \
                            | grep -E "$motif" | sort -u)
    [ "${#versions[@]}" -gt 1 ] || continue
    local i
    for ((i = 0; i < ${#versions[@]} - 1; i++)); do
      info "périmé : ${versions[i]}"
      rm -f "$rep/${versions[i]}" && supprimes=$((supprimes + 1))
    done
  done
  # Les fichiers écartés pour somme incorrecte ne servent à rien non plus.
  while IFS= read -r s; do
    info "écarté  : $(basename "$s")"; rm -f "$s"; supprimes=$((supprimes + 1))
  done < <(find "$ISO" "$OUTILS" -name '*.SUSPECT' 2>/dev/null)
  manifeste
  bleu "$supprimes fichier(s) supprimé(s) — $(df -h "$DEPOT" | awk 'NR>1{print $4}') disponibles"
}

# DÉCLARER LES ARCHIVES, SINON ELLES SONT INVISIBLES.
#
# Un .zim posé dans le répertoire de kiwix-serve n'apparaît pas pour autant : il
# faut l'inscrire dans library.xml. Laissée à la main, cette déclaration produit
# le cas le plus déroutant du dispositif : des dizaines de gigaoctets d'archives
# téléchargées et une interface Kiwix vide, sans la moindre erreur signalée.
#
# On la fait donc ici, à chaque passage, et de façon idempotente : kiwix-manage
# ignore un livre déjà présent. Non bloquant — un dépôt complet dont la
# bibliothèque n'est pas à jour reste utile, l'inverse serait faux.
declarer_kiwix() {
  local n=0 z manage=""
  [ -d "$KIWIX" ] || return 0
  # LE BINAIRE N'EST PAS DANS LE PATH. Le paquet YunoHost l'installe dans le
  # répertoire de l'application — /var/www/kiwix — et non dans /usr/bin. Un
  # « command -v » seul renonce donc toujours, et la déclaration automatique n'a
  # jamais lieu : des gigaoctets d'archives et une interface Kiwix qui ignore la
  # dernière.
  for c in kiwix-manage /var/www/kiwix/kiwix-manage /opt/kiwix/kiwix-manage; do
    if command -v "$c" >/dev/null 2>&1 || [ -x "$c" ]; then manage="$c"; break; fi
  done
  if [ -z "$manage" ]; then
    mal "kiwix-manage introuvable : les archives ne seront pas déclarées"
    info "  elles sont dans $KIWIX mais l'interface Kiwix ignorera les nouvelles"
    return 0
  fi
  echo
  bleu "Déclaration des archives Kiwix"
  for z in "$KIWIX"/*.zim; do
    [ -f "$z" ] || continue
    if "$manage" "$KIWIX/library.xml" add "$z" >/dev/null 2>&1; then
      n=$((n + 1))
    fi
  done
  # Le compte fait foi, pas le nombre d'appels réussis : c'est ce que l'interface
  # affichera réellement.
  local livres
  livres="$(grep -c '<book' "$KIWIX/library.xml" 2>/dev/null || true)"
  ok "bibliothèque à jour — ${livres:-0} livre(s) pour $n archive(s) traitée(s)"
  # kiwix-serve relit sa bibliothèque au démarrage seulement.
  systemctl restart kiwix 2>/dev/null \
    && info "kiwix relancé pour recharger la bibliothèque" || true
}

main() {
  case "${1:-}" in
    --manifeste) manifeste; ok "manifeste régénéré : $MANIFESTE"; return 0 ;;
    --verifier)  verifier; return 0 ;;
    --nettoyer)  nettoyer; return 0 ;;
    --liste)
      for e in "${CATALOGUE[@]}"; do
        IFS='|' read -r l _ b _ _ <<<"$e"
        printf '  %-28s %s\n' "$l" "$b"
      done
      return 0 ;;
  esac

  command -v curl >/dev/null || { mal "curl absent"; return 1; }
  mkdir -p "$ISO" "$OUTILS"

  bleu "Dépôt : $DEPOT"
  bleu "Place disponible : $(df -h "$DEPOT" | awk 'NR>1{print $4}')"
  [ -n "$LIMITE" ] && bleu "Débit bridé à $LIMITE"
  echo

  preparer_manuels
  echo

  # Fedora publie ses versions dans des répertoires numérotés. On prend le plus
  # élevé plutôt que d'en figer un : sinon le script récupérerait la même version
  # pendant des années sans que rien ne le signale.
  local FEDORA_VER
  FEDORA_VER="$(curl -fsL --max-time 45 \
    "https://download.fedoraproject.org/pub/fedora/linux/releases/" 2>/dev/null \
    | grep -oE '>[0-9]{2}/' | tr -d '>/' | sort -n | tail -1)"
  [ -n "$FEDORA_VER" ] && bleu "Fedora : version $FEDORA_VER" \
    || info "version de Fedora indéterminée — ses entrées échoueront"

  local reussis=0 echoues=0
  for entree in "${CATALOGUE[@]}"; do
    IFS='|' read -r libelle dossier base fsommes motif <<<"$entree"
    base="${base//\{VER\}/$FEDORA_VER}"
    fsommes="${fsommes//\{VER\}/$FEDORA_VER}"
    if traiter "$libelle" "$dossier" "$base" "$fsommes" "$motif"; then
      reussis=$((reussis + 1))
    else
      echoues=$((echoues + 1))
    fi
  done

  for entree in "${DIRECTS[@]}"; do
    IFS='|' read -r libelle dossier url <<<"$entree"
    local rep="$DEPOT/$dossier"
    [ "$dossier" = "statiques" ] && rep="$OUTILS/statiques"
    case "$dossier" in secours|forensic) rep="$ISO/$dossier" ;; esac
    mkdir -p "$rep"
    # Deux busybox porteraient le même nom : on les distingue par leur variante,
    # sans quoi le second écraserait le premier en silence.
    local nom="${url##*/}"
    [ -z "$nom" ] && nom="install-yunohost.sh"
    case "$url" in
      *static-binaries/master/*)
        # « …/master/aarch64/curl » devient « curl-aarch64 » : sans cela les six
        # binaires s'écraseraient deux à deux, tous nommés « busybox », « curl »…
        nom="$(basename "$url")-$(basename "$(dirname "$url")")" ;;
    esac
    if [ -s "$rep/$nom" ]; then ok "$libelle — déjà présent"; reussis=$((reussis + 1)); continue; fi
    bleu "$libelle → $nom"
    if telecharger "$url" "$rep/$nom"; then
      chmod +x "$rep/$nom" 2>/dev/null || true
      ok "$libelle — téléchargé (somme non publiée : à vérifier à la main)"
      reussis=$((reussis + 1))
    else
      mal "$libelle — échec"; echoues=$((echoues + 1))
    fi
  done

  # Le dépôt tourne sous son propre compte : sans cela, il verrait les fichiers
  # sans pouvoir les gérer, et personne ne comprendrait pourquoi.
  if id filebrowser >/dev/null 2>&1; then
    chown -R filebrowser:filebrowser "$ISO" "$OUTILS" 2>/dev/null || true
  fi

  # ── Documentation des outils ──────────────────────────────────────────────
  if command -v wget >/dev/null 2>&1; then
    echo
    bleu "Documentation des outils"
    for entree in "${DOCUMENTATIONS[@]}"; do
      IFS='|' read -r lib dos url plafond _ _ <<<"$entree"
      if documenter "$lib" "$dos" "$url" "$plafond"; then
        reussis=$((reussis + 1))
      else
        echoues=$((echoues + 1))
      fi
    done

    # Les documentations dont le site n'est pas copiable : on prend la source.
    for entree in "${DOCS_GIT[@]}"; do
      IFS='|' read -r lib dos depot sous _ _ <<<"$entree"
      if documenter_git "$lib" "$dos" "$depot" "$sous"; then
        reussis=$((reussis + 1))
      else
        echoues=$((echoues + 1))
      fi
    done

    index_documentation
  else
    mal "wget absent : documentation des outils non récupérée"
  fi

  # busybox arm64 : aucune source web ne le publie en statique avec une somme.
  # Le paquet Debian, lui, est couvert par les index SIGNÉS d'apt — c'est la
  # seule voie réellement vérifiée pour l'architecture de l'arche.
  STEP_BB="$OUTILS/statiques"
  if command -v apt-get >/dev/null 2>&1 && [ ! -s "$STEP_BB/busybox-static-arm64" ]; then
    mkdir -p "$STEP_BB"
    tmpdeb="$(mktemp -d)"
    if (cd "$tmpdeb" && apt-get download busybox-static >/dev/null 2>&1) \
       && dpkg-deb -x "$tmpdeb"/busybox-static_*.deb "$tmpdeb/x" 2>/dev/null \
       && cp "$tmpdeb/x/bin/busybox" "$STEP_BB/busybox-static-arm64" 2>/dev/null; then
      chmod +x "$STEP_BB/busybox-static-arm64"
      cp "$tmpdeb"/busybox-static_*.deb "$STEP_BB/" 2>/dev/null || true
      ok "busybox statique arm64 — extrait du paquet Debian (vérifié par apt)"
      reussis=$((reussis + 1))
    else
      mal "busybox statique arm64 — extraction du paquet Debian en échec"
      echoues=$((echoues + 1))
    fi
    rm -rf "$tmpdeb"
  fi

  declarer_kiwix

  manifeste
  echo
  bleu "Terminé : $reussis réussis, $echoues en échec"
  bleu "Manifeste : $MANIFESTE"
  [ "$echoues" -eq 0 ]
}

main "$@"
