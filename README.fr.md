# Codex with ChatGPT · Swift pour macOS

[English](README.md) | [繁體中文](README.zh-TW.md) | [简体中文](README.zh-CN.md) | **Français** | [Español](README.es.md) | [日本語](README.ja.md) | [한국어](README.ko.md)

Une app macOS qui simplifie les allers-retours entre Codex et ChatGPT Quick Chat.

Le flux de travail habituel consiste à commencer la discussion dans Quick Chat, puis à choisir « Ajouter à Codex » au moment de passer à l’implémentation. ChatGPT et Codex étant deux systèmes distincts, retrouver ensuite cette conversation demande généralement de la rechercher soi-même. Cette app ajoute un bouton à côté de chaque session Codex : un premier clic ouvre Quick Chat, puis les clics suivants ramènent à la même conversation.

Lorsque ChatGPT a besoin du contexte du projet, vous pouvez aussi joindre les fichiers du dossier de travail de la session depuis ce même menu. Les ensembles volumineux sont automatiquement divisés en lots et les fichiers sensibles peuvent être exclus avec `.c2cignore`. Les boutons sont injectés à l’ouverture de l’app ; si vous ne les utilisez pas, le fonctionnement habituel de Codex et ChatGPT reste inchangé.

![Actions Quick Chat, pièces jointes du projet et règles d’exclusion pour une session Codex](docs/images/session-quick-chat-actions.png)

**Nécessite macOS 13 ou version ultérieure. Compatible Apple Silicon et Intel. Aucun besoin de Node.js ou npm.** L’app et le CLI pilotent uniquement l’interface de bureau en local via CDP. Aucun serveur HTTP, flux OAuth, service MCP, tunnel ou connexion publique n’est lancé. Sparkle 2 assure les mises à jour automatiques signées.

## Téléchargement et installation

Version actuelle : **v0.1.2**

- [Télécharger pour Apple Silicon (M1/M2/M3/M4)](https://github.com/irons163/codex-with-chatgpt-macos/releases/download/v0.1.2/CodexWithChatGPT-0.1.2-apple-silicon.dmg)
- [Télécharger pour Intel](https://github.com/irons163/codex-with-chatgpt-macos/releases/download/v0.1.2/CodexWithChatGPT-0.1.2-intel.dmg)
- [Voir la dernière version et les notes de mise à jour](https://github.com/irons163/codex-with-chatgpt-macos/releases/latest)

Ouvrez le DMG, faites glisser `CodexWithChatGPT.app` dans `/Applications`, puis lancez l’app. Elle est signée avec un Developer ID et notariée par Apple. Les prochaines versions seront proposées par le module de mise à jour Sparkle intégré.

## Utilisation

1. Ouvrez Codex, puis lancez `CodexWithChatGPT.app`. L’app reste dans la barre des menus et ajoute automatiquement les boutons d’action aux sessions.
2. Cliquez sur l’icône à droite d’une session Codex.
3. Choisissez une action :
   - **Ouvrir／continuer Quick Chat** : crée une conversation au premier clic, puis revient à cette même conversation par la suite.
   - **Joindre les fichiers du projet** : joint à Quick Chat les fichiers source et texte du dossier de travail de la session.
   - **Modifier les règles d’exclusion** : ouvre le fichier `.c2cignore` du projet afin de choisir les fichiers qui ne doivent jamais être joints.

Une fois Quick Chat lié, cliquez sur le « × » à côté de la session pour supprimer le lien. Au-delà de 20 fichiers, les pièces jointes sont automatiquement divisées en lots. Envoyez le message en cours, puis choisissez de nouveau « Joindre les fichiers du projet » pour charger le lot suivant.

Si les boutons n’apparaissent pas, choisissez « Réinjecter » dans l’app de la barre des menus.

## Limites de sécurité des pièces jointes

- Ne lance aucun serveur HTTP, flux OAuth, service MCP, tunnel ou port d’écoute public.
- Analyse uniquement le dossier de travail de la session ; les fichiers extérieurs et les liens symboliques ne sont jamais joints.
- `.c2cignore` regroupe des exclusions de sécurité visibles et modifiables ; `.gitignore` est également appliqué.
- Chaque lot est limité à 20 fichiers et 8 Mio. Chaque fichier est limité à 1 Mio et doit être un texte UTF-8 valide.
- Les pièces jointes correspondent au contenu des fichiers au moment du clic. Elles ne donnent pas à ChatGPT un accès continu au projet local.

Le [skill d’utilisation](skill/SKILL.md) inclus fournit un flux de travail Swift/macOS et n’est pas installé automatiquement dans votre configuration Codex personnelle.

## Licence

Ce projet est distribué sous [licence MIT](LICENSE) et n’est pas un produit officiel d’OpenAI.
