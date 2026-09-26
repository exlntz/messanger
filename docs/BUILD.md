# Сборка VOICE для iOS

Этот документ описывает сборку независимого iOS-приложения VOICE и установку неподписанного IPA через AltStore или Sideloadly.

## Требования

- iPhone или iPad с iOS 17 или новее.
- Для локальной сборки: macOS, Xcode 26, Homebrew и XcodeGen.
- Liquid Glass используется только на iOS 26 через проверки доступности в SwiftUI-коде приложения. На iOS 17 используется обычный SwiftUI fallback.
- Bundle ID: `com.exlntz.voice`.
- Версия приложения: `0.1.0`, build `1`.
- LiveKit Swift SDK закреплен на `2.17.0`.
- Supabase используется через пользовательский REST-клиент в коде приложения. Отдельный Supabase SDK в Swift Package Manager не добавлен.

## Что делает CI

Workflow `.github/workflows/ios.yml` запускается на `push` в `main` и вручную через `workflow_dispatch`.

CI делает следующее:

1. Выбирает Xcode 26 через поиск `/Applications/Xcode_26*.app`.
2. Устанавливает XcodeGen.
3. Генерирует оригинальную иконку VOICE 1024×1024 без Pillow, только через Python stdlib.
4. Генерирует `VOICE.xcodeproj` из `project.yml`.
5. Разрешает Swift packages.
6. Собирает Release для `generic/platform=iOS` без подписи.
7. Проверяет, что исполняемый файл iPhoneOS содержит `arm64`.
8. Упаковывает `Payload/VOICE.app` в `VOICE-unsigned.ipa`.
9. Загружает артефакт `VOICE-unsigned-ipa` и диагностические логи.

Workflow не публикует релизы, не использует secrets и не требует paid signing entitlements.

GitHub публично документирует `macos-26` как generally available runner. Workflow все равно проверяет установленный Xcode через `/Applications/Xcode_26*.app`, чтобы не зависеть от системного symlink.

## Локальная сборка

```bash
brew install xcodegen
sudo xcode-select -s "$(find /Applications -maxdepth 1 \( -type d -o -type l \) -name 'Xcode_26*.app' | sort | tail -n 1)/Contents/Developer"
python3 scripts/generate_app_icon.py
xcodegen generate --spec project.yml
xcodebuild -resolvePackageDependencies -project VOICE.xcodeproj -scheme VOICE
xcodebuild \
  -project VOICE.xcodeproj \
  -scheme VOICE \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build | tee build.log
bash scripts/package_unsigned_ipa.sh
```

После успешной команды файл будет здесь:

```text
VOICE-unsigned.ipa
```

Не считайте сборку успешной, пока `xcodebuild` или GitHub Actions фактически не завершились без ошибки.

## Установка через AltStore

1. Установите AltServer на Mac или Windows с официального сайта AltStore.
2. Подключите iPhone кабелем и включите доверие к этому компьютеру.
3. Установите AltStore на устройство через AltServer.
4. Войдите в AltStore с Apple ID.
5. Скачайте `VOICE-unsigned.ipa` из артефактов GitHub Actions.
6. Откройте IPA на устройстве через AltStore.
7. Нажмите Install.
8. Если iOS попросит доверять профилю разработчика, откройте Settings → General → VPN & Device Management и подтвердите доверие к своему Apple ID.

Бесплатный Apple ID подписывает приложение на 7 дней. До истечения срока откройте AltStore в той же сети, где работает AltServer, и обновите подпись. После истечения 7 дней приложение нужно подписать снова.

## Установка через Sideloadly

1. Установите Sideloadly с официального сайта.
2. Подключите iPhone или iPad кабелем.
3. Перетащите `VOICE-unsigned.ipa` в окно Sideloadly.
4. Введите Apple ID.
5. Нажмите Start и дождитесь окончания подписи и установки.
6. Если iOS попросит доверять профилю разработчика, откройте Settings → General → VPN & Device Management и подтвердите доверие к своему Apple ID.

Для бесплатного Apple ID срок подписи также 7 дней. Затем установку нужно обновить.

## Ограничения неподписанной и бесплатной установки

- Push-уведомления не работают без платного Apple Developer Program, APNs и соответствующих entitlements.
- Входящий звонок может быть показан только пока приложение активно или находится в foreground. Надежные входящие звонки в фоне требуют push-инфраструктуру и отдельную настройку, которой здесь нет.
- В `Info.plist` включен только `audio` background mode. Он предназначен для активного звонка или записи голосового сообщения. VoIP background mode и APNs entitlement не добавлены.
- PhotosPicker не требует полного доступа к фотобиблиотеке. Поэтому `NSPhotoLibraryUsageDescription` не добавлен.
- Сквозное шифрование не заявлено. Не используйте приложение для секретных данных, пока E2EE не спроектирован, не реализован и не проверен.

## Настройка сервера

Приложение должно иметь экран настройки сервера, где пользователь задает адрес backend, Supabase REST URL и параметры LiveKit, которые предоставляет backend. Точные поля и правила проверки задаются кодом приложения и backend-документацией.

Backend должен выдавать LiveKit token и обслуживать кастомный REST-контур Supabase. Смотрите backend-документ проекта, когда он будет добавлен родительской задачей.

## Безопасность

- Устанавливайте IPA только из доверенного репозитория и из ожидаемого workflow run.
- Проверяйте, что workflow не использовал secrets и не публиковал релизы автоматически.
- Не передавайте Apple ID, Supabase keys или LiveKit secrets в репозиторий.
- Для публичного тестирования используйте TestFlight или другой официальный канал подписи.
