# SwiftCut

Petit éditeur de clips pour macOS, pensé pour les enregistrements d'écran : on ouvre une vidéo (ou on la glisse sur la fenêtre), on coupe les passages inutiles, puis on exporte dans le format voulu (MOV → MP4, HEVC, GIF…).

SwiftUI + AVFoundation, sans aucune dépendance externe. Interface en français.

## Lancer l'app

- **Depuis Xcode** : ouvrir `SwiftCut.xcodeproj`, puis ⌘R.
- **En ligne de commande** : `./scripts/build.sh` compile l'app dans `build/SwiftCut.app`
  (`./scripts/build.sh --install` la copie aussi dans `/Applications`).

Prérequis : macOS 15 ou plus récent, Xcode 16 ou plus récent.

## Utilisation

1. **Ouvrir** : glisser une vidéo sur la fenêtre ou sur l'icône du Dock, ou ⌘O.
2. **Couper**, avec l'un des deux modes (sélecteur en haut de la fenêtre) :
   - **Rogner** (par défaut, ⌘1) — comme sur iPhone : on fait glisser les poignées du cadre pour ne garder qu'un passage.
     Le cadre devient jaune dès qu'on rogne, et la lecture s'arrête aux bords du passage.
     **I** / **O** (ou « Début ici » / « Fin ici ») placent le début et la fin à la tête de lecture.
   - **Découper** (⌘2) — montage libre, pour retirer plusieurs passages :
     - glisser sur la timeline pour sélectionner un passage, puis ⌫ pour le supprimer ;
     - ou placer la tête de lecture et appuyer sur **I** (début) / **O** (fin), puis ⌫ ;
     - **⌘B** (ou **B**) scinde à la tête de lecture ; cliquer un segment le sélectionne ;
     - les boutons ⇤ / ⇥ suppriment tout ce qui précède / suit la tête de lecture.
3. **Recadrer** (facultatif, touche **C** ou bouton « Recadrer ») — comme sur iPhone : un cadre apparaît sur la vidéo ;
   on fait glisser ses coins ou ses bords pour le redimensionner, l'intérieur pour le déplacer.
   Formats proposés : Libre, Original, Carré, 16:9, 9:16, 4:3, 3:4, 4:5. **Entrée** valide, **Échap** annule.
   En dehors de l'outil, l'aperçu montre directement l'image recadrée.
4. **Flouter** (facultatif, touche **F** ou bouton « Flouter ») : on dessine des rectangles sur la vidéo pour masquer
   un mot de passe, une adresse e-mail, un visage… Chaque zone se déplace et se redimensionne, en **Flou** ou en **Pixels**,
   avec une intensité réglable. Par défaut elle couvre toute la vidéo ; « Début ici » / « Fin ici » la limitent à un moment
   précis (la zone reste attachée au contenu même si l'on coupe ensuite). ⌫ supprime la zone sélectionnée.
   L'aperçu montre les flous en direct, exactement comme à l'export.
5. **Exporter** : ⌘E, choisir le format, puis l'emplacement.
   En mode Rogner, seul le passage encadré est exporté ; en mode Découper, toute la timeline.

Les deux modes se combinent : passer de Rogner à Découper applique le rognage à la timeline (⌘Z pour annuler),
et les coupes faites en mode Découper restent visibles en mode Rogner.

Tout est non destructif : le fichier d'origine n'est jamais modifié, et ⌘Z / ⇧⌘Z annulent ou rétablissent chaque modification.

## Formats d'export

| Format | Encodage | Remarques |
| --- | --- | --- |
| MP4 | H.264, HEVC | Résolution (2160p → 480p), images/s et qualité réglables |
| MP4 / MOV | Sans réencodage | Instantané et sans perte (copie du flux d'origine) |
| MOV | H.264, HEVC, ProRes 422 | ProRes pour retravailler la vidéo dans un logiciel de montage |
| GIF | — | Largeur et images/s réglables, idéal pour un README ou un ticket |
| Audio | AAC (.m4a) | Bande son seule |

Bon à savoir :

- Le recadrage et les flous s'appliquent à tous les exports vidéo et au GIF ; la résolution se règle sur la zone recadrée.
  Une image recadrée ou floutée doit être réencodée : la copie « sans réencodage » n'est alors pas proposée.
- Le H.264 est limité à 4096 px : une vidéo 5K est réduite automatiquement (le HEVC garde la pleine résolution).
- En « sans réencodage », les coupes sont exactes dans QuickTime et la plupart des lecteurs ; certains lecteurs web peuvent afficher quelques images en trop autour des coupes.
- La taille annoncée pour un réencodage est un plafond : un écran peu animé donne souvent un fichier bien plus léger.

## Raccourcis

| Touche | Action |
| --- | --- |
| ⌘1 / ⌘2 | Mode Rogner / mode Découper |
| Espace | Lecture / pause |
| J / K / L | Arrière / pause / avant (répéter pour accélérer) |
| ← / → | Image précédente / suivante (⇧ : une seconde) |
| ↑ / ↓ | Coupe (ou bord du passage) précédente / suivante |
| I / O | Début / fin du passage (Rogner) ou de la sélection (Découper) |
| C | Recadrer l'image (Entrée : valider, Échap : annuler) |
| F | Flouter des zones (⌫ : supprimer la zone, Entrée : terminer) |
| ⌘B ou B | Scinder (Découper) |
| ⌫ | Supprimer la sélection ou le segment sélectionné (Découper) |
| ⌥⌘← / ⌥⌘→ | Début / fin du passage (Rogner) · supprimer tout avant / après (Découper) |
| Échap | Tout désélectionner |
| Pincer, ⌘ + molette, ⌘= / ⌘- / ⌘0 | Zoom de la timeline |

La liste complète est dans l'app : touche **?** ou menu Aide › Raccourcis clavier.

## Organisation du code

```
SwiftCut/
├── App/            Point d'entrée, délégué (ouverture depuis le Finder/Dock), menus
├── Model/          EditList (segments et coupes), CropRect (cadre de recadrage),
│                   BlurRegion (zones floutées et rendu Core Image partagé aperçu / export),
│                   EditorModel (modes, rognage, recadrage, lecture, annulation),
│                   MediaInfo (analyse du fichier), CompositionBuilder (montage AVFoundation)
├── Export/         ExportSettings (formats et réglages), VideoExporter (réencodage, copie, GIF, audio),
│                   ExportJob (progression)
├── Timeline/       Timeline AppKit dessinée sur mesure (pellicule à poignées ou segments), vignettes, forme d'onde
├── Views/          Fenêtre principale, aperçu, outils Recadrer et Flouter, barre d'outils, feuilles d'export et d'aide
└── Support/        Raccourcis clavier, couleur de l'app, formatage
```

Le montage est une simple liste de segments de la source (`EditList`) ; en mode Rogner, l'export n'en garde que
le passage encadré (`EditList.trimmed(to:)`). L'aperçu et l'export reconstruisent une `AVMutableComposition` à partir de cette liste ; l'export passe ensuite par `AVAssetReader`/`AVAssetWriter` (réencodage), `AVAssetExportSession` (copie sans réencodage, audio) ou ImageIO (GIF).

## Contribuer

Les issues et pull requests sont les bienvenues. Pour une modification importante, ouvrez d'abord une issue pour en discuter.
Le projet se compile sans compte développeur : la signature « Sign to Run Locally » suffit pour l'exécuter sur votre Mac.

## Licence

[MIT](LICENSE)
