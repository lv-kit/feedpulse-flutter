# リリース手順

1. `pubspec.yaml` の `version` を更新し、`CHANGELOG.md` に同じバージョンの節を追加する。
2. `flutter analyze` / `flutter test` / `dart pub publish --dry-run`（警告 0）を確認する。
3. 上記を PR で `main` に取り込む。
4. `main` で `git tag vX.Y.Z` を打って push する。
5. `dart pub publish` で pub.dev に公開する（公開は取り消せない。メンテナが実行する）。
