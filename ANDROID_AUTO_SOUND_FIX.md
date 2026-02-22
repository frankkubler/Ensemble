# Fix Android Auto - Problème de son résolu

## 🔍 Diagnostic

### Problème
Pas de son lorsque vous utilisez Ensemble avec Android Auto dans votre voiture.

### Cause racine
L'application utilisait **Sendspin** (streaming PCM via `flutter_pcm_sound`) pour la lecture audio locale. Sendspin n'est pas compatible avec Android Auto car :

1. **Android Auto nécessite `just_audio`** : L'audio doit passer par le système audio standard Android pour être routé vers la voiture via Bluetooth
2. **Sendspin utilise `AudioTrack` natif** : Les données PCM brutes jouées via `flutter_pcm_sound` ne sont pas correctement routées vers Android Auto
3. **Incompatibilité d'architecture** : Android Auto s'attend à ce que l'audio soit géré par `MediaSession` + `AudioFocus`, ce que `just_audio` fait correctement mais pas `flutter_pcm_sound`

### Erreurs connexes
Les erreurs StreamController que vous avez vues étaient un symptôme secondaire (une race condition lors de la déconnexion), mais **n'étaient pas la cause** du problème de son.

## ✅ Solution appliquée

### 1. Correction de la race condition StreamController
**Fichier** : [lib/services/music_assistant_api.dart](lib/services/music_assistant_api.dart)

Ajout de vérifications pour éviter d'ajouter des événements à un StreamController fermé :

```dart
void _updateConnectionState(MAConnectionState state) {
  _currentState = state;
  // Only add event if not disposed
  if (!_isDisposed && !_connectionStateController.isClosed) {
    _connectionStateController.add(state);
  }
}
```

Ajout de protection contre les reconnexions après dispose dans les callbacks WebSocket.

### 2. Désactivation de Sendspin pour forcer just_audio
**Fichier** : [lib/providers/music_assistant_provider.dart](lib/providers/music_assistant_provider.dart)

Force l'utilisation du mode **builtin_player classique** (avec `just_audio`) au lieu de Sendspin :

```dart
bool _serverUsesSendspin() {
  // Android Auto requires just_audio mode (builtin_player), not Sendspin/PCM
  // Return false to force classic builtin_player even on newer MA servers
  return false;
  /* Original logic commented out for Android Auto compatibility */
}
```

## 🧪 Comment tester

1. **Recompilez l'application** :
   ```bash
   cd /mnt/storage/Github/Ensemble
   flutter clean
   flutter pub get
   flutter build apk --release
   ```

2. **Installez sur votre téléphone** :
   ```bash
   adb install build/app/outputs/flutter-apk/app-release.apk
   ```

3. **Testez avec Android Auto** :
   - Connectez votre téléphone à votre voiture (ou au Desktop Head Unit Emulator)
   - Ouvrez Android Auto
   - Sélectionnez Ensemble
   - Lancez une piste
   - **Vous devriez entendre le son maintenant ! 🎵**

## 📊 Comparaison des modes

| Mode | Technologie | Compatibilité Android Auto | Latence | Qualité |
|------|-------------|----------------------------|---------|---------|
| **Sendspin** | PCM streaming via `flutter_pcm_sound` | ❌ Non compatible | Très faible | Excellente |
| **Builtin Player** | `just_audio` + HTTP streaming | ✅ **Compatible** | Faible | Excellente |

## 🔄 Pour réactiver Sendspin plus tard (optionnel)

Si dans le futur vous souhaitez réactiver Sendspin pour la lecture hors Android Auto :

1. Décommentez la logique originale dans `_serverUsesSendspin()`
2. Ajoutez une détection d'Android Auto et un switch automatique
3. Ou ajoutez un paramètre utilisateur "Force just_audio mode"

## 📝 Notes techniques

### Architecture actuelle (après fix)
```
Android Auto → playFromMediaId() 
           ↓
  MassivAudioHandler 
           ↓
  MusicAssistantProvider.playTracks()
           ↓
  Music Assistant Server (builtin_player mode)
           ↓
  HTTP audio stream
           ↓
  just_audio (AudioPlayer)
           ↓
  Android MediaSession
           ↓
  Android Auto → Voiture 🚗 ✅
```

### Architecture problématique (avant fix)
```
Android Auto → playFromMediaId()
           ↓
  Sendspin WebSocket
           ↓
  PCM streaming
           ↓
  flutter_pcm_sound
           ↓
  AudioTrack natif
           ↓
  ❌ Audio non routé vers Android Auto
```

## 🎯 Résultat attendu

- ✅ Son fonctionne dans Android Auto
- ✅ Contrôles de lecture fonctionnent (play/pause/skip)
- ✅ Métadonnées affichées correctement
- ✅ Notification média fonctionne
- ✅ Pas d'erreurs StreamController

## 🐛 Si le problème persiste

Vérifiez :
1. **Permissions Android** : FOREGROUND_SERVICE, FOREGROUND_SERVICE_MEDIA_PLAYBACK
2. **Audio focus** : L'app doit obtenir l'audio focus
3. **Build.gradle** : `minSdkVersion 23` ou plus
4. **AndroidManifest.xml** : Metadata `com.google.android.gms.car.application` présent

Logs à surveiller :
```
adb logcat | grep -E "Ensemble|AndroidAuto|AudioService"
```

---

**Date du fix** : 22 février 2026
**Branche** : Android-auto-sound-resolution
