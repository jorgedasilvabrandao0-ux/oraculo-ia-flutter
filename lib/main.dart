import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() { WidgetsFlutterBinding.ensureInitialized(); runApp(const OraculoApp()); }

class ApiException implements Exception {
  final String message;
  ApiException(this.message);
  @override String toString() => message;
}

class OraculoApi {
  final Dio dio;
  OraculoApi(String url) : dio = Dio(BaseOptions(
    baseUrl: url.replaceAll(RegExp(r'/$'), ''),
    connectTimeout: const Duration(seconds: 12),
    receiveTimeout: const Duration(seconds: 25),
    headers: {'Content-Type': 'application/json'},
  ));

  Future<Map<String, dynamic>> call(String method, String path, [Map<String, dynamic>? data]) async {
    try {
      final Response<dynamic> response = await dio.request<dynamic>(path,
        data: data, options: Options(method: method));
      final body = response.data;
      if (body is Map) return Map<String, dynamic>.from(body);
      throw ApiException('Resposta inesperada do servidor.');
    } on DioException catch (e) {
      final detail = e.response?.data;
      String? message;
      if (detail is Map && detail['detail'] != null) {
        final value = detail['detail'];
        if (value is List) {
          message = value.map((item) => item is Map ? (item['msg'] ?? item).toString() : item.toString()).join('; ');
        } else {
          message = value.toString();
        }
      }
      if (e.response?.statusCode == 503) message ??= 'Catálogo indisponível: verifique as fotos no backend.';
      if (e.response?.statusCode == 404) message ??= 'Jogador ou partida não encontrado.';
      throw ApiException(message ?? (e.response == null
          ? 'Não foi possível conectar ao backend. Verifique a URL e a internet.'
          : 'Erro HTTP ${e.response!.statusCode}.'));
    }
  }
  Future<void> health() async { await call('GET', '/health'); }
  Future<Map<String, dynamic>> createPlayer(String name) => call('POST', '/jogadores', {'nome': name, 'persona': 'oraculo'});
  Future<Map<String, dynamic>> player(String id) => call('GET', '/jogadores/${Uri.encodeComponent(id)}');
  String gamePath(String id, String mode) => mode == 'objetos' ? '/ia/objetos/${Uri.encodeComponent(id)}' : '/ia/${Uri.encodeComponent(id)}';
  Future<Map<String, dynamic>> start(String id, String mode) => call('POST', '${gamePath(id, mode)}/iniciar');
  Future<Map<String, dynamic>> next(String id, String mode) => call('GET', '${gamePath(id, mode)}/proxima');
  Future<Map<String, dynamic>> answer(String id, String mode, String question, String answer) => call('POST', '${gamePath(id, mode)}/responder', {'pergunta_id': question, 'resposta': answer});
  Future<Map<String, dynamic>> confirm(String id, String mode, bool correct) => call('POST', '${gamePath(id, mode)}/confirmar', {'acertou': correct});
  Future<Map<String, dynamic>> suggest(String id, String name, String trait) => call('POST', '/ia/${Uri.encodeComponent(id)}/sugerir', {'nome': name, 'caracteristica_distintiva': trait});
  Future<Map<String, dynamic>> stats() => call('GET', '/ia/estatisticas/base');
}

class OraculoApp extends StatelessWidget {
  const OraculoApp({super.key});
  @override Widget build(BuildContext context) => MaterialApp(
    title: 'O Oráculo da Bola de Cristal', debugShowCheckedModeBanner: false,
    theme: ThemeData(brightness: Brightness.dark, useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFC6A0FF), brightness: Brightness.dark),
      scaffoldBackgroundColor: const Color(0xFF100D20),
      textTheme: GoogleFonts.cinzelTextTheme(ThemeData.dark().textTheme)),
    home: const GameScreen(),
  );
}

class GameScreen extends StatefulWidget {
  const GameScreen({super.key});
  @override State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> {
  final nameController = TextEditingController();
  final urlController = TextEditingController(text: 'http://10.0.2.2:8000');
  OraculoApi? api;
  String? playerId;
  Map<String, dynamic>? step;
  bool busy = false;
  bool hasGame = false;
  String mode = 'personagens';
  String? error;
  int? count;
  String? pendingAnswer;
  String? pendingQuestion;
  String? pendingMode;
  static const answers = <String, String>{
    'SIM': 'Sim', 'NAO': 'Não', 'PROVAVELMENTE_SIM': 'Provavelmente sim',
    'PROVAVELMENTE_NAO': 'Provavelmente não', 'NAO_SEI': 'Não sei', 'TAMBEM': 'Também',
  };

  @override void initState() { super.initState(); _restore(); }
  @override void dispose() { nameController.dispose(); urlController.dispose(); super.dispose(); }

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    urlController.text = prefs.getString('api_url') ?? urlController.text;
    nameController.text = prefs.getString('player_name') ?? '';
    playerId = prefs.getString('player_id');
    mode = prefs.getString('game_mode') ?? 'personagens';
    pendingAnswer = prefs.getString('pending_answer');
    pendingQuestion = prefs.getString('pending_question');
    pendingMode = prefs.getString('pending_mode') ?? (pendingQuestion == null ? null : mode);
    api = OraculoApi(urlController.text.trim());
    setState(() {});
    if (playerId != null) await _resume();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('api_url', urlController.text.trim());
    await prefs.setString('player_name', nameController.text.trim());
    await prefs.setString('game_mode', mode);
    if (playerId != null) await prefs.setString('player_id', playerId!);
    if (pendingAnswer != null && pendingQuestion != null) {
      await prefs.setString('pending_answer', pendingAnswer!);
      await prefs.setString('pending_question', pendingQuestion!);
      await prefs.setString('pending_mode', pendingMode ?? mode);
    } else {
      await prefs.remove('pending_answer');
      await prefs.remove('pending_question');
      await prefs.remove('pending_mode');
    }
  }

  Future<void> _perform(Future<void> Function() action) async {
    if (busy) return;
    setState(() { busy = true; error = null; });
    try { await action(); }
    catch (e) { if (mounted) setState(() => error = e.toString()); }
    finally { if (mounted) setState(() => busy = false); }
  }

  Future<void> _connect() => _perform(() async {
    final url = urlController.text.trim();
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasAuthority || !['http', 'https'].contains(uri.scheme)) {
      throw ApiException('Informe uma URL válida, como http://192.168.1.10:8000');
    }
    if (nameController.text.trim().length < 2) throw ApiException('Informe um nome com pelo menos 2 letras.');
    api = OraculoApi(url);
    await api!.health();
    if (playerId == null) {
      final player = await api!.createPlayer(nameController.text.trim());
      final id = player['id'] ?? player['jogador_id'];
      if (id == null) throw ApiException('O backend não retornou o ID do jogador.');
      playerId = id.toString();
    } else {
      await api!.player(playerId!);
    }
    await _save();
    try { count = (await api!.stats())['personagens'] as int?; } catch (_) { /* optional */ }
    if (mounted) setState(() {});
    await _loadNext();
  });

  Future<void> _resume() => _perform(() async {
    if (playerId == null) return;
    api = OraculoApi(urlController.text.trim());
    await api!.player(playerId!);
    await _loadNext();
  });

  Future<void> _loadNext() async {
    if (playerId == null || api == null) return;
    try {
      final current = await api!.next(playerId!, mode);
      if (mounted) setState(() { step = current; hasGame = true; });
    } on ApiException catch (e) {
      if (e.message.contains('Inicie a IA primeiro') || e.message.contains('Partida não iniciada')) {
        if (mounted) setState(() { step = null; hasGame = false; });
      } else { rethrow; }
    }
  }

  Future<void> _start() => _perform(() async {
    if (pendingAnswer != null) throw ApiException('Sincronize sua resposta pendente antes de iniciar outra partida.');
    if (playerId == null || api == null) throw ApiException('Conecte-se primeiro.');
    final next = await api!.start(playerId!, mode);
    pendingAnswer = null; pendingQuestion = null; pendingMode = null;
    await _save();
    if (mounted) setState(() { step = next; hasGame = true; });
  });

  Future<void> _answer(String answer) => _perform(() async {
    final question = step?['id']?.toString();
    if (question == null || playerId == null || api == null) return;
    pendingAnswer = answer; pendingQuestion = question; pendingMode = mode;
    await _save(); // Save before sending: offline retry is explicit to avoid duplicate submissions.
    final result = await api!.answer(playerId!, mode, question, answer);
    pendingAnswer = null; pendingQuestion = null; pendingMode = null;
    await _save();
    if (mounted) setState(() => step = result);
  });

  Future<void> _retryPending() => _perform(() async {
    if (pendingAnswer == null || pendingQuestion == null || playerId == null || api == null) return;
    if (pendingMode != null && pendingMode != mode) throw ApiException('Volte ao modo da resposta pendente para sincronizá-la.');
    // If the server already advanced, don't send the answer twice.
    final serverStep = await api!.next(playerId!, mode);
    if (serverStep['tipo'] != 'pergunta' || serverStep['id'] != pendingQuestion) {
      pendingAnswer = null; pendingQuestion = null; pendingMode = null;
      await _save();
      if (mounted) setState(() => step = serverStep);
      return;
    }
    final result = await api!.answer(playerId!, mode, pendingQuestion!, pendingAnswer!);
    pendingAnswer = null; pendingQuestion = null; pendingMode = null;
    await _save();
    if (mounted) setState(() => step = result);
  });

  Future<void> _confirm(bool yes) => _perform(() async {
    if (playerId == null || api == null) return;
    final result = await api!.confirm(playerId!, mode, yes);
    if (mounted) setState(() => step = result);
  });

  Future<void> _suggest() async {
    final name = TextEditingController(); final trait = TextEditingController();
    await showDialog<void>(context: context, builder: (context) => AlertDialog(
      title: const Text('Ensine o Oráculo'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: name, decoration: const InputDecoration(labelText: 'Nome do personagem')),
        TextField(controller: trait, decoration: const InputDecoration(labelText: 'Característica distintiva')),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(onPressed: () async {
          if (name.text.trim().length < 2 || trait.text.trim().length < 5) return;
          try {
            await api!.suggest(playerId!, name.text.trim(), trait.text.trim());
            if (context.mounted) { Navigator.pop(context); ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sugestão enviada para revisão.'))); }
          } catch (e) { if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString()))); }
        }, child: const Text('Enviar'))],
    ));
    name.dispose(); trait.dispose();
  }

  Widget _panel(Widget child) => Container(width: double.infinity,
    padding: const EdgeInsets.all(22),
    decoration: BoxDecoration(color: const Color(0xFF211832), borderRadius: BorderRadius.circular(24),
      border: Border.all(color: const Color(0xFF614687))), child: child);

  Widget _button(String label, VoidCallback? onTap, {bool primary = true}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: SizedBox(width: double.infinity, child: primary
      ? FilledButton(onPressed: busy ? null : onTap, child: Padding(padding: const EdgeInsets.all(13), child: Text(label, textAlign: TextAlign.center)))
      : OutlinedButton(onPressed: busy ? null : onTap, child: Padding(padding: const EdgeInsets.all(12), child: Text(label, textAlign: TextAlign.center)))));

  Widget _content() {
    if (playerId == null) return _panel(Column(mainAxisSize: MainAxisSize.min, children: [
        Image.asset('assets/oraculo.png', height: 170),
      const Text('Entre no reino do Oráculo', textAlign: TextAlign.center, style: TextStyle(fontSize: 19)),
      const SizedBox(height: 15),
      TextField(controller: nameController, decoration: const InputDecoration(labelText: 'Nome do jogador', prefixIcon: Icon(Icons.person))),
      const SizedBox(height: 12),
      TextField(controller: urlController, keyboardType: TextInputType.url, decoration: const InputDecoration(labelText: 'URL do backend Python', prefixIcon: Icon(Icons.link), helperText: 'No celular físico, use o IP do servidor; não localhost.')),
      const SizedBox(height: 18), _button('Conectar ao Oráculo', _connect),
    ]));
    if (!hasGame || step == null) return _panel(Column(children: [
      const Icon(Icons.auto_awesome, size: 65, color: Color(0xFFE3C4FF)),
      const SizedBox(height: 12),
      Text('Bem-vindo, ${nameController.text.trim()}!', textAlign: TextAlign.center, style: const TextStyle(fontSize: 21)),
      const SizedBox(height: 10),
      const Text('Escolha uma categoria e pense em um item com foto cadastrada. Eu tentarei adivinhar!', textAlign: TextAlign.center),
      const SizedBox(height: 14),
      SegmentedButton<String>(segments: const [ButtonSegment(value: 'personagens', label: Text('Personagens'), icon: Icon(Icons.people)), ButtonSegment(value: 'objetos', label: Text('Objetos'), icon: Icon(Icons.category))], selected: {mode}, onSelectionChanged: (busy || pendingAnswer != null) ? null : (selection) async { setState(() { mode = selection.first; hasGame = false; step = null; }); await _save(); await _resume(); }),
      if (count != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text('$count personagens na base (não necessariamente jogáveis)')),
      const SizedBox(height: 20), _button('Começar a adivinhação', _start),
      _button('Verificar partida anterior', _resume, primary: false),
    ]));
    final kind = step!['tipo']?.toString();
    if (kind == 'pergunta') return _panel(Column(children: [
      const Icon(Icons.psychology_alt, size: 48, color: Color(0xFFDAB5FF)),
      const SizedBox(height: 10),
      Text('Pergunta ${(step!['perguntas_feitas'] as num? ?? 0).toInt() + 1}', style: const TextStyle(color: Color(0xFFC9A3F5))),
      const SizedBox(height: 12),
      Text(step!['texto']?.toString() ?? 'Pergunta indisponível', textAlign: TextAlign.center, style: const TextStyle(fontSize: 21)),
      if (step!['dica_tambem'] != null) Padding(padding: const EdgeInsets.symmetric(vertical: 10), child: Text(step!['dica_tambem'].toString(), textAlign: TextAlign.center, style: const TextStyle(fontSize: 12))),
      const SizedBox(height: 16),
      for (final entry in answers.entries) _button(entry.value, () => _answer(entry.key), primary: entry.key == 'SIM'),
    ]));
    if (kind == 'palpite') {
      final image = step!['imagem_url']?.toString();
      final validImage = image != null && Uri.tryParse(image)?.scheme == 'https';
      return _panel(Column(children: [
        const Text('Minha previsão é...', style: TextStyle(fontSize: 17)),
        const SizedBox(height: 15),
        if (validImage) ClipRRect(borderRadius: BorderRadius.circular(16), child: Image.network(image!,
          height: 185, fit: BoxFit.contain,
          errorBuilder: (_, __, ___) => const Icon(Icons.broken_image, size: 60))),
        const SizedBox(height: 14),
        Text(step!['personagem']?.toString() ?? 'Item desconhecido', textAlign: TextAlign.center, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
        const SizedBox(height: 18),
        _button('Sim, você acertou!', () => _confirm(true)),
        _button('Não, continue tentando', () => _confirm(false), primary: false),
      ]));
    }
    if (kind == 'fim') return _panel(Column(children: [
      Icon(step!['acertou'] == true ? Icons.emoji_events : Icons.sentiment_dissatisfied, size: 65, color: const Color(0xFFFFD585)),
      const SizedBox(height: 14),
      Text(step!['acertou'] == true ? 'O Oráculo acertou!' : 'Ainda preciso aprender!', textAlign: TextAlign.center, style: const TextStyle(fontSize: 23)),
      if (step!['motivo'] != null) Padding(padding: const EdgeInsets.all(10), child: Text(step!['motivo'].toString(), textAlign: TextAlign.center)),
      const SizedBox(height: 15),
      if (mode == 'personagens') _button('Sugerir personagem para revisão', _suggest, primary: false),
      _button('Nova partida', _start),
    ]));
    return _panel(Column(children: [
      Text('Resposta desconhecida: ${jsonEncode(step)}'),
      _button('Atualizar', _resume),
    ]));
  }

  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(backgroundColor: Colors.transparent, title: const Text('O ORÁCULO', style: TextStyle(letterSpacing: 2)), centerTitle: true,
      actions: [IconButton(tooltip: 'Configurar servidor', onPressed: busy ? null : () async {
        setState(() { playerId = null; hasGame = false; step = null; pendingAnswer = null; pendingQuestion = null; pendingMode = null; });
        final prefs = await SharedPreferences.getInstance(); await prefs.remove('player_id'); await prefs.remove('pending_answer'); await prefs.remove('pending_question'); await prefs.remove('pending_mode');
      }, icon: const Icon(Icons.settings))]),
    body: SafeArea(child: SingleChildScrollView(padding: const EdgeInsets.all(20), child: Center(child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520), child: Column(children: [
        const SizedBox(height: 10),
        const Icon(Icons.blur_circular, size: 88, color: Color(0xFFC8A2FF)),
        const SizedBox(height: 8),
        const Text('A BOLA DE CRISTAL', textAlign: TextAlign.center, style: TextStyle(fontSize: 18, letterSpacing: 3)),
        const SizedBox(height: 22),
        if (busy) const LinearProgressIndicator(),
        if (error != null) Padding(padding: const EdgeInsets.only(bottom: 12), child: _panel(Column(children: [
          const Icon(Icons.wifi_off, color: Colors.orangeAccent), const SizedBox(height: 8),
          Text(error!, textAlign: TextAlign.center, style: const TextStyle(fontSize: 13)),
          if (playerId != null) _button('Tentar reconectar', _resume, primary: false),
        ]))),
        if (pendingAnswer != null) Padding(padding: const EdgeInsets.only(bottom: 12), child: _panel(Column(children: [
          Text('Resposta pendente salva neste celular (${pendingMode ?? mode}).'),
          _button('Sincronizar resposta pendente', _retryPending),
        ]))),
        _content(),
        const SizedBox(height: 18),
        const Text('As respostas são salvas antes do envio. A retomada depende da persistência do backend.', textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: Colors.white54)),
      ]))))),
  );
}
