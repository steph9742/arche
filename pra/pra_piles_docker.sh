#!/bin/bash
# pra_piles_docker.sh — remettre les piles Docker en marche après un démarrage.
#
# L'arche s'éteint chaque nuit, par conception. Or les fichiers « compose »
# viennent de la production et ne portent pas tous une politique de
# redémarrage : après une extinction, des conteneurs restent à terre et le
# mandataire rend 502 sans que rien ne le signale. La restauration nocturne, qui
# relance tout, masque le problème : il n'apparaît qu'après un démarrage manuel.
#
# Corriger les « compose » côté production est la bonne réponse de fond, et elle
# redescend par la sauvegarde. Ce script est le filet : il ne restaure rien, ne
# télécharge rien, ne décide rien. Il démarre ce qui est déjà là.
#
#   PRA_DOCKER_ROOT   racine des piles (défaut /opt/pra-docker)
#
set -uo pipefail

RACINE="${PRA_DOCKER_ROOT:-/opt/pra-docker}"
LOG="${PRA_LOG:-/var/log/pra_docker_restore.log}"

log() { printf '[%s] piles au démarrage : %s\n' "$(date '+%F %T')" "$*" >> "$LOG" 2>/dev/null || true; }

command -v docker >/dev/null 2>&1 || { log "docker absent — rien à faire"; exit 0; }
[ -d "$RACINE" ] || { log "$RACINE absent — rien à faire"; exit 0; }

# ON NE DÉMARRE RIEN PENDANT UNE RESTAURATION.
#
# Elle arrête et relance les piles elle-même, dans un ordre qu'elle maîtrise ;
# s'y superposer produirait deux processus qui se disputent les mêmes conteneurs.
#
# On interroge systemd, qui sait. Le PID ne sert que pour le repli en processus
# détaché, et avec un garde-fou : « kill -0 0 » RÉUSSIT TOUJOURS, car il vise le
# groupe de processus courant — et le fichier contient « 0 » quand la
# restauration a été lancée par systemd-run, qui ne rend pas de PID. Sans la
# garde « pid > 0 », ce contrôle concluait « une restauration tourne » à chaque
# exécution, indéfiniment, et le filet ne relançait plus rien en silence.
_restauration_tourne() {
  systemctl is-active --quiet arche-restauration.service 2>/dev/null && return 0
  local pid
  pid="$(cat /run/arche-restauration.pid 2>/dev/null || true)"
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$pid" -gt 0 ] || return 1
  kill -0 "$pid" 2>/dev/null
}

if _restauration_tourne; then
  log "restauration en cours — on ne s'en mêle pas"
  exit 0
fi

demarrees=0
for d in "$RACINE"/*/; do
  [ -d "$d" ] || continue
  nom="$(basename "$d")"
  [ "$nom" = ".work" ] && continue
  # ON NE PASSE PAS « -f » : C'EST TOUTE LA DIFFÉRENCE.
  #
  # « docker compose -f fichier.yml » n'assemble PAS
  # « docker-compose.override.yml » — cette fusion n'a lieu que par découverte
  # automatique, en se plaçant dans le dossier. Or c'est l'override que la
  # restauration écrit, et il porte l'essentiel : la liaison du port à la boucle
  # locale et le montage de l'autorité interne, sans laquelle les conteneurs ne
  # valident pas les certificats internes. Relancer sans lui casse le SSO et
  # publie le port sur toutes les interfaces.
  compose=""
  for c in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
    [ -f "$d$c" ] && { compose="$d$c"; break; }
  done
  [ -n "$compose" ] || continue

  # Combien tournent déjà ? Une pile complète n'a pas besoin qu'on y touche.
  total="$( (cd "$d" && docker compose ps -a --format '{{.Service}}') 2>/dev/null | wc -l)"
  actifs="$( (cd "$d" && docker compose ps --format '{{.Service}}') 2>/dev/null | wc -l)"
  [ "${total:-0}" -gt 0 ] || continue
  if [ "${actifs:-0}" -ge "${total:-0}" ]; then
    continue
  fi

  # « up -d » est idempotent : il laisse en place ce qui tourne et ne relance que
  # ce qui manque. Les conteneurs en « restart: no » qui ont fini leur travail —
  # les migrations — restent à l'arrêt, ce qui est correct.
  if (cd "$d" && docker compose up -d) >/dev/null 2>&1; then
    apres="$( (cd "$d" && docker compose ps --format '{{.Service}}') 2>/dev/null | wc -l)"
    # ON NE JOURNALISE QUE CE QUI A CHANGÉ : « 5/6 -> 5/6 » à chaque démarrage
    # laisserait croire à un échec répété, alors que le sixième conteneur est une
    # migration en « restart: no » dont l'arrêt est le comportement correct. Une
    # ligne qui alerte toujours cesse d'être lue.
    if [ "${apres:-0}" -gt "${actifs:-0}" ]; then
      log "$nom : $actifs/$total -> $apres/$total"
      demarrees=$((demarrees + 1))
    fi
  else
    # UNE TÂCHE DÉJÀ PASSÉE BLOQUE TOUTE LA PILE.
    #
    # Une pile qui déclare « depends_on: migrate: service_completed_successfully »
    # relance sa migration au démarrage — laquelle échoue, puisque la base porte
    # déjà le schéma restauré. La condition n'étant pas remplie, les services qui
    # en dépendent ne démarrent pas du tout : la pile reste à terre pour une tâche
    # qui a pourtant fait son travail.
    #
    # On repart donc service par service, sans les dépendances, en sautant
    # précisément les tâches dont une CONDITION D'ACHÈVEMENT dépend : ce sont les
    # travaux ponctuels, pas les services.
    mapfile -t _ponctuels < <((cd "$d" && docker compose config --format json) 2>/dev/null \
      | python3 -c 'import json,sys
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
vus = set()
for s in (d.get("services") or {}).values():
    dep = s.get("depends_on") or {}
    if isinstance(dep, dict):
        for nom, cond in dep.items():
            if isinstance(cond, dict) and cond.get("condition") == "service_completed_successfully":
                vus.add(nom)
for n in sorted(vus): print(n)' 2>/dev/null)

    repris=0
    while IFS= read -r svc; do
      [ -n "$svc" ] || continue
      passe=0
      for j in "${_ponctuels[@]:-}"; do [ "$svc" = "$j" ] && passe=1; done
      [ "$passe" = 1 ] && continue
      (cd "$d" && docker compose up -d --no-deps "$svc") >/dev/null 2>&1 \
        && repris=$((repris + 1))
    done < <((cd "$d" && docker compose config --services) 2>/dev/null)

    apres="$( (cd "$d" && docker compose ps --format '{{.Service}}') 2>/dev/null | wc -l)"
    if [ "${apres:-0}" -gt "${actifs:-0}" ]; then
      log "$nom : $actifs/$total -> $apres/$total (sans les tâches ponctuelles : ${_ponctuels[*]:-aucune})"
      demarrees=$((demarrees + 1))
    else
      log "$nom : ÉCHEC du démarrage — voir « docker compose -f $compose up -d »"
    fi
  fi
done

[ "$demarrees" -gt 0 ] && log "$demarrees pile(s) relancée(s)"
exit 0
