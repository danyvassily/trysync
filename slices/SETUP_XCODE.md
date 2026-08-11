# TriSync — Configuration Xcode & Sandbox

Guide de mise en place du projet Xcode pour **TriSync** (macOS 14+, SwiftUI, App Sandbox, Apple Silicon).

## 1. Créer le projet
- Xcode → **File → New → Project…**
- Plateforme : **macOS** → modèle **App**.
- Options : **Interface = SwiftUI**, **Language = Swift**, **sans Core Data**, **sans tests**.

## 2. Supprimer TriSyncApp.swift
- **Supprimer** le fichier `TriSyncApp.swift` généré par défaut.
- Le point d'entrée `@main` est fourni par le code système (`System.swift`), intégré au `ContentView.swift` final.
- **Le garder = erreur de doublon de point d'entrée** (`multiple commands produce` / attribut `main` dupliqué).

## 3. Coller le code final
- Coller l'intégralité du code final (System + UI + SyncEngine) dans **ContentView.swift**.

## 4. App Sandbox
1. Sélectionner la target **TriSync**.
2. Onglet **Signing & Capabilities**.
3. **« + Capability »** → **App Sandbox** → activer (ON).
4. Dans la section **File Access** : **User Selected File → Read Only**.
5. **Aucun autre entitlement requis** : `NSOpenPanel` et le glisser-déposer depuis le Finder accordent l'accès aux fichiers automatiquement dans la sandbox.
6. *(Optionnel)* Pour persister une bibliothèque entre les lancements : **security-scoped bookmarks** + accès **Read/Write**.

## 5. Cible
- **Target → General → Deployment Target** : ≥ **14.0**.
- **Architectures** : « Standard architectures (Apple Silicon) » (valeur par défaut, arm64).

## 6. Lancer
- **⌘R** pour compiler et lancer.
- Ajouter jusqu'à **3 vidéos** (bouton **Ouvrir…** ou glisser-déposer), puis **Play**.

## 7. Dépannage

| Symptôme | Cause probable |
|---|---|
| `multiple commands produce` ou doublon `@main` | `TriSyncApp.swift` n'a pas été supprimé |
| Fichiers grisés dans le panneau d'ouverture | `allowedContentTypes` trop restrictif (vérifier `.movie` / `.video`) |
| Accès refusé à un fichier hors sandbox | « User Selected File » manquant ; Read/Write requis pour des bookmarks persistants |
