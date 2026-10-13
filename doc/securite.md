# Sécurité

Un serveur de secours est une cible intéressante : il contient une copie
complète des données de production, et il est souvent moins surveillé que
l'original. Ce document dit contre quoi l'outil protège, comment, et ce qu'il ne
protège pas.

## Modèle de menace

L'adversaire considéré en premier est un **rançongiciel** qui a obtenu les droits
d'administration sur le serveur de production. Il cherche alors les sauvegardes
pour les chiffrer ou les détruire, afin que la victime n'ait pas le choix.

Deux conséquences ont structuré tout le dispositif.

### Le modèle est « pull », jamais « push »

C'est l'arche qui ouvre la connexion et tire les sauvegardes. La production ne
détient **aucun identifiant** vers l'arche, n'a aucun moyen de la joindre, et
n'a pas besoin de savoir où elle se trouve. Un attaquant maître de la production
ne trouve donc rien qui mène au réplica.

Inverser ce sens — pousser les sauvegardes depuis la production — suffirait à
annuler la protection. Aucun cas particulier ne le justifie.

La seule chose qui sorte de l'arche est un **reçu** déposé après chaque
restauration, sur un canal **en écriture seule** : l'arche dépose et ne relit
rien. Si la production y laissait un fichier que l'arche vient lire et honorer,
elle commanderait l'arche, et le modèle serait inversé sans que personne ne s'en
aperçoive.

Le reçu est construit par liste blanche de champs — jamais par recopie d'un
fichier d'état — et un garde-fou refuse l'envoi s'il contient une adresse IP ou
le nom de la machine. À savoir tout de même : la production connaît l'adresse de
l'arche par son journal d'authentification, puisque c'est l'arche qui se
connecte. Ce qu'on tient, c'est qu'elle ne détienne aucun **moyen** d'agir.

### Le magasin est en écriture unique

La réplication emploie `rsync --ignore-existing` : un fichier déjà présent dans
le magasin n'est **jamais** réécrit. Une archive chiffrée sur la production ne
peut donc pas remplacer la bonne copie côté arche.

Cette règle a une conséquence qu'il faut garder en tête en modifiant le code :
toute hypothèse du genre « ce fichier sera retéléchargé » est fausse. Un fichier
douteux est mis en **quarantaine** — renommé, pas supprimé : si la production
envoie des fichiers corrompus, ces copies sont des indices.

## Détecter un chiffrement avant de restaurer

Restaurer une archive chiffrée écraserait le dernier bon état du réplica. Les
contrôles ont donc lieu **avant** toute désinstallation, et dans cet ordre :

| Contrôle | Ce qu'il voit |
|---|---|
| Témoins et quorum | plusieurs machines injoignables la même nuit : incident large, on s'abstient |
| Canaris | fichiers appâts sur la production, dont l'empreinte est vérifiée à distance |
| Notes de rançon | motifs caractéristiques dans le listing de l'archive |
| Taille | écart à la **médiane** des archives précédentes, et non à la veille |
| Nombre d'applications | une chute brutale est suspecte |
| Incompressibilité | un échantillon devenu incompressible évoque un chiffrement |

Deux choix méritent d'être expliqués.

**Les canaris sont des appâts, pas des sentinelles.** Les rançongiciels ciblent
par extension : un canari est donc un document d'apparence ordinaire
(`.docx`, `.pdf`, `.xlsx`) posé au milieu de vraies données. Et on ne les protège
**jamais** en écriture (`chattr +i`) : un canari protégé du chiffrement ne serait
plus chiffré, donc ne signalerait plus rien.

**L'incompressibilité avertit, elle ne bloque pas.** Une archive saine de
données déjà comprimées est presque incompressible. Ce contrôle produirait un
refus chaque nuit : il est volontairement non bloquant.

Le verdict a trois issues : contenu de canari **modifié** bloque toujours ; une
seule absence alerte et laisse passer ; au-delà d'un seuil, on bloque. Un fichier
qui disparaît est du ménage, plusieurs la même nuit sont un événement.

## Secrets

| Secret | Où il vit | Rotation |
|---|---|---|
| Clé SSH de l'arche vers la production | sur l'arche, compte root | à révoquer côté production |
| Secret du bot de notification | `/etc/pra/pra.conf`, root 600 | régénérer côté Nextcloud |
| Jeton du tableau de bord machine | `/etc/yunobox/token`, root 600 | supprimer le fichier et relancer |
| Mot de passe d'accès de secours à l'interface | empreinte dans la configuration | regénérer l'empreinte |

Quelques règles appliquées partout dans le code :

- **Un secret ne passe jamais en argument de commande.** `/proc/<pid>/cmdline`
  est lisible par tous les utilisateurs locaux ; `environ` ne l'est que par le
  propriétaire du processus. Les secrets passent donc par l'environnement.
- **Le fichier de configuration est `source`é par des scripts root.** Toute
  valeur écrite y est un vecteur d'exécution privilégiée : l'interface web type
  chaque réglage, interdit une liste de caractères d'échappement, et le
  composant privilégié **revalide tout** avant d'écrire — il ne croit jamais
  l'interface sur parole.
- **La vérification TLS reste active.** Les destinations sont épinglées par
  adresse IP tout en conservant le nom pour le SNI, plutôt que de désactiver le
  contrôle du certificat : désactiver masquerait les défauts au lieu de les
  corriger.

## Surface d'exposition du réplica

- Les ports des piles Docker sont republiés sur `127.0.0.1`. Les piles en réseau
  « host » échappent à ce mécanisme : l'outil les signale, à l'exploitant
  d'arbitrer.
- L'interface web écoute sur `127.0.0.1` et doit être exposée derrière le SSO,
  restreinte aux administrateurs. Un accès de secours par mot de passe existe
  **à dessein** : l'authentification unique peut reposer sur une application
  restaurée, donc cassée précisément le jour où l'on a besoin de l'interface.
- La page de secours et l'état publié par la production sont **sans
  authentification**, délibérément : ils ne portent que ce qu'on accepte de
  rendre public — adresses d'accès, « restaurée ou non », date. Chaque champ
  ajouté est un champ qu'on ne peut plus reprendre.

## Ce que l'outil ne fait pas

- **Il ne chiffre pas son disque.** Un réplica transportable contenant une copie
  des données de production devrait être sur un disque chiffré ; c'est à
  l'exploitant de le mettre en place.
- **Il ne protège pas d'un attaquant déjà présent sur le réplica.** Les contrôles
  portent sur ce qui arrive de la production.
- **Il ne garantit pas l'alerte.** Les notifications partent vers un service
  hébergé sur la production : en cas de sinistre majeur, elles n'arriveront pas.
  Le journal local et l'état sur l'arche font foi.
- **Il ne remplace pas une répétition.** Un dispositif de reprise qui n'a jamais
  été manœuvré par quelqu'un d'autre que son auteur n'est pas éprouvé.
