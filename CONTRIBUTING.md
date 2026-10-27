# Contribuer un package

1. Forkez le dépôt et copiez `packages/salut/` vers `packages/<votre-nom>/`.
2. Écrivez le manifeste `package.lua` et vos fichiers.
3. Lancez `go run ./tools/mkindex` pour vérifier, puis ouvrez une pull request. La CI refait les vérifications. Une fois la PR fusionnée, le package est disponible pour tous après un `pkg update`.

## Le manifeste

```lua
return {
  name = "snake2",                 -- = nom du dossier ; minuscules, chiffres, - et _ (24 max)
  version = "1.0.0",               -- X.Y.Z
  description = "Snake en couleurs", -- une ligne, 120 caractères max
  author = "Ada Lovelace",         -- facultatif
  license = "MIT",                 -- facultatif
  bin = { "snake2" },              -- facultatif : commandes du prompt A>
  depends = { "tui" },             -- facultatif : autres packages du registre
}
```

Le manifeste ne contient que des données : chaînes, nombres et listes. Les fonctions, les appels et les variables y sont refusés.

## Règles

- **Fichiers :** ils sont à plat dans le dossier, sans sous-dossiers. Chaque fichier fait **64 Ko au plus**, ce qui est la limite d'un script sur la machine. Un package fait 256 Ko au plus en tout, parce que le disque `A:` fait environ 1,9 Mo.
- **Lua :** c'est du Lua 5.4 avec des nombres sur 32 bits. Il n'y a ni `io` ni `os`, et la mémoire est limitée à 96 Ko par script. L'API (`term`, `key`, `fs`, `net`, `win`...) est décrite dans le README de TERMINA.
- **Commandes :** chaque nom de `bin` doit avoir son fichier `<nom>.lua`. Après installation, taper `<nom>` au prompt le lance. Un fichier `<nom>.lua` à la racine de `A:` reste prioritaire, alors choisissez des noms qui ne risquent pas de collisionner (évitez par exemple `hello` ou `snake`).
- **Modules :** un fichier `util.lua` de votre package se charge avec `require "<package>.util"`, qui le cherche dans `A:\pkg\<package>\util.lua`. Un autre package qui vous a dans ses `depends` peut faire de même.
- **Applications du bureau :** un fichier dont l'en-tête contient `-- @app Nom` (et facultativement `-- @icon nom`) apparaît sur le bureau `win`, comme les applications à la racine de `A:`.
- **Versions :** toute modification d'un package publié doit monter sa version, sinon la CI refuse la PR. Les machines ne mettent à jour un package que si sa version augmente.

## Sécurité

Un package s'exécute avec les mêmes droits que n'importe quel programme Lua de la machine. Il peut notamment lire et écrire tout `A:` et utiliser le réseau. Les PR sont relues avant d'être fusionnées : gardez le code lisible (pas de code minifié ni obscurci) et n'envoyez pas de données vers un serveur sans le dire dans la description.

Sur la machine, chaque fichier téléchargé est vérifié par sa somme SHA-1 inscrite dans l'index. L'index lui-même passe par HTTPS, mais la machine ne vérifie pas les certificats TLS.
