# O Oráculo da Bola de Cristal — Flutter

Frontend Flutter para os endpoints reais de IA do backend Python V14.3.

## Instalação
1. Instale Flutter SDK (em um PC ou ambiente de compilação Flutter).
2. Crie o projeto Android nativo caso necessário: `flutter create --platforms=android .`
3. Execute `flutter pub get` e `flutter run`.
4. Inicie o FastAPI a partir da pasta do backend: `uvicorn api:app --host 0.0.0.0 --port 8000`.
5. No aplicativo, informe a URL **acessível pelo celular** (ex.: `http://192.168.1.20:8000`). `10.0.2.2` funciona apenas no emulador Android padrão. Para produção use HTTPS.

## Integração
- `GET /health`
- `POST /jogadores`, `GET /jogadores/{id}`
- `POST /ia/{id}/iniciar`, `GET /ia/{id}/proxima`
- `POST /ia/{id}/responder`, `POST /ia/{id}/confirmar`
- `POST /ia/{id}/sugerir`, `GET /ia/estatisticas/base`

## Importante
- O backend V14.3 ainda filtra personagens usando imagens R2. Sem fotos válidas, `/ia/{id}/iniciar` retorna 503. É necessário adaptar o backend para Cloudinary e povoar o catálogo.
- URLs Cloudinary HTTPS retornadas como `imagem_url` são exibidas automaticamente.
- `shared_preferences` guarda jogador, URL e uma resposta pendente para reenvio manual seguro. **Não é uma fila de múltiplas respostas offline** e não garante persistência do servidor.
- O projeto não contém chaves privadas nem `API Secret` Cloudinary.
- O código não foi compilado neste ambiente se Flutter SDK não estiver instalado.

## Android em HTTP local
Se estiver testando com `http://` em Android, configure `android:usesCleartextTraffic="true"` **apenas na build de desenvolvimento** dentro do elemento `<application>` de `android/app/src/main/AndroidManifest.xml`. Para produção, prefira HTTPS e remova essa permissão.
