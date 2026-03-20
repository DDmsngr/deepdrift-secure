# P2 Refactor Plan (Sprint 3+)

## Цели
1. Уменьшить связанность UI-экранов с крипто/сокет/хранилищем.
2. Вынести бизнес-логику в use-case слой.
3. Сделать код тестируемым на уровне domain/application без Flutter UI.

## Целевые слои
- `lib/domain/`: сущности и интерфейсы репозиториев.
- `lib/application/`: use-cases и мапперы.
- `lib/infrastructure/`: адаптеры к текущим сервисам.
- `lib/presentation/`: экраны/виджеты + состояние.

## Пошаговая миграция
### Этап 1: Подготовка
- Интерфейсы над `SocketService` / `StorageService`.
- DI-точка в `main.dart`.
### Этап 2: Use-case пилот
- `SendMessageUseCase`, `LoadRecentChatsUseCase`.
### Этап 3: Тестирование
- Unit-тесты use-case с mock/fake.
### Этап 4: Декомпозиция больших экранов
- Разделить `home_screen.dart` и `chat_screen.dart` на controller/view/state.

## Definition of Done
- Критические сценарии покрыты unit-тестами use-case.
- `flutter analyze` и `flutter test` зелёные в CI.
- Документация актуальна.
