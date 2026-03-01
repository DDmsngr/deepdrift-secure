# DDChat — Secure E2E Messenger

Защищённый мессенджер на Flutter с end-to-end шифрованием, анонимными идентификаторами и поддержкой медиафайлов.

---

## Криптография

| Слой | Алгоритм |
|---|---|
| Key Exchange | X25519 ECDH |
| Message Encryption | ChaCha20-Poly1305 |
| Message Signing | Ed25519 |
| Key Derivation | HKDF per-contact shared secret |
| Password Export | Argon2id + ChaCha20-Poly1305 |

Каждая пара контактов получает уникальный shared secret через X25519 ECDH. Сообщения подписываются Ed25519 — иконка 🔒/⚠️ в каждом пузырьке показывает статус верификации подписи. Ключи хранятся локально в Hive; при экспорте зашифрованы Argon2id с паролем пользователя.

---

## Архитектура

```
lib/
├── main.dart                   # MultiProvider на корне, FCM background handler
├── splash_screen.dart
├── home_screen.dart            # Список чатов, QR-сканер, управление контактами
├── chat_screen.dart            # Экран чата (~1940 строк)
├── settings_screen.dart        # Настройки, смена пароля, Device Fingerprint
│
├── models/
│   └── chat_models.dart        # MsgType, SignatureStatus, утилиты форматирования
│
├── widgets/
│   ├── message_bubble.dart     # StatelessWidget пузырька — без зависимостей на сервисы
│   └── video_players.dart      # VideoNotePlayer (круглый) + VideoGalleryPlayer
│
├── providers/
│   └── app_providers.dart      # SocketProvider, StorageProvider, CipherProvider
│
├── socket_service.dart         # WebSocket синглтон, реконнект, FCM токен
├── storage_service.dart        # Hive синглтон, per-key mutex (race-free)
├── crypto_service.dart         # SecureCipher — всё шифрование
├── identity_service.dart       # Генерация и хранение UID
└── notification_service.dart   # FCM + flutter_local_notifications
```

### Ключевые решения

**`MessageBubble` — `StatelessWidget`.**
Получает данные (`msg`, `myUid`, `reactions`) и 6 коллбэков (`onRetryDownload`, `onPlayVoice` и т.д.) — не знает ни о сервисах, ни о `ChatScreen`. Тестируется изолированно.

**`SocketService` / `StorageService` — синглтоны через Provider.**
`context.read<SocketProvider>().service` — зависимость явная и заменяемая в тестах. `StorageProvider.saveMessage()` вызывает `notifyListeners()` для реактивного обновления списков.

**`StorageService` — per-key sequential Future chain.**
Hive не thread-safe для read-modify-write. Мьютекс через цепочку Future'ов исключает race condition при параллельных write.

**Офлайн-очередь на сервере.**
Сервер (FastAPI + Redis) хранит сообщения до 7 дней. При подключении клиент получает накопленные сообщения по глобальной и per-contact очередям.

---

## Фичи

**Сообщения**
- Текст, фото (одиночное и мультивыбор), видео из галереи
- Видеокружки (VideoNote) — запись с фронтальной камеры, круглый плеер
- Голосовые сообщения (m4a)
- Файлы произвольного типа с иконкой по MIME
- Ответ (Reply), пересылка (Forward), редактирование, удаление у себя / для всех
- Реакции emoji (лонг-тап → выбор)
- Статус доставки: ⏳ pending → ✓ sent → ✓✓ delivered → ✓✓ read (cyan)
- Иконка верификации Ed25519-подписи на каждом входящем сообщении

**Медиа**
- Автоматическое скачивание при получении; при сбое — кнопка «повторить загрузку»
- Полноэкранный просмотр фото с pinch-to-zoom
- Просмотр профиля контакта в full-screen с Hero-анимацией
- Сохранение медиа в галерею устройства (gal)

**Чат**
- Пагинация: 50 сообщений на загрузку, scroll вверх → догрузка истории
- Локальное хранение: до 1000 сообщений на чат (Hive)
- Поиск по истории сообщений
- Индикатор «печатает...»
- Online / Last seen (обновляется при connect/disconnect)

**Контакты**
- Добавление по UID вручную или через QR-сканер (mobile_scanner)
- Кастомное отображаемое имя (хранится локально)
- Генерация QR с собственным UID (qr_flutter)

**Безопасность**
- «Сбросить ключи» в меню сообщения — восстановление без переустановки при Authentication failed
- Device Fingerprint (SHA-256 публичных ключей) в настройках
- Экспорт/импорт зашифрованных ключей с паролем (Argon2id)

**Уведомления**
- Data-only FCM push (текст сообщения в пуше не передаётся)
- Background handler показывает локальное уведомление через flutter_local_notifications
- Тап по уведомлению → открывает нужный чат (foreground / background / cold start)

---

## Бэкенд

Python (FastAPI) + Redis + Firebase Admin SDK.

```
Эндпоинты:
  WS   /ws            WebSocket соединение
  POST /upload        Загрузка зашифрованного файла
  GET  /download/:id  Скачивание файла (404 если не найден)
  GET  /health        Статус сервиса
```

Файлы передаются зашифрованными — клиент шифрует перед загрузкой и расшифровывает после скачивания. Сервер не имеет доступа к открытым данным.

---

## Установка

### Требования

- Flutter SDK ≥ 3.0.0
- Android SDK / Android Studio
- Firebase проект с Cloud Messaging; `google-services.json` в `android/app/`

### Шаги

```bash
git clone https://github.com/DDmsngr/deepdrift-secure
cd deepdrift-secure
flutter pub get
flutter run
```

### Подключение к серверу

По умолчанию клиент подключается к `wss://deepdrift-backend.onrender.com/ws`.
Адрес можно сменить в настройках приложения.

---

## Протокол (v3.0)

При подключении клиент отправляет `init` с `my_uid` и `protocol_version`. Сервер отвечает `uid_assigned` и доставляет офлайн-очередь. Все сообщения — JSON через WebSocket. Медиафайлы — отдельный HTTP POST `/upload`.

Реконнект: экспоненциальный backoff, до 50 попыток. Heartbeat ping каждые 10 секунд.

### Структура сообщения на проводе

```json
{
  "type": "message",
  "id": "<uuid>",
  "target_uid": "888888",
  "encrypted_text": "<base64>",
  "signature": "<base64 Ed25519>",
  "messageType": "text | image | voice | file | video_note | video_gallery",
  "mediaData": "FILE_ID:<server_file_id>",
  "fileName": "photo.jpg",
  "fileSize": 204800,
  "mimeType": "image/jpeg",
  "replyToId": "<uuid | null>",
  "time": 1740825600000
}
```

---

## Лицензия

MIT
