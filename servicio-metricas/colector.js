// Colector de métricas de Jarvis como servicio (panel en Vercel + base en Neon) para el Prometheus de la VM.
// - Una vez por hora (INTERVALO_SEGUNDOS) lee los totales del esquema "metricas" de Neon (migración 019) con el rol
//   jarvis_metricas, que solo ve esos totales. No consulta en cada lectura de Prometheus: así Neon duerme el resto
//   del tiempo y no se gastan las horas de cómputo del plan gratis.
// - Expone /metrics (formato de Prometheus) con los últimos valores, solo en la red interna de Docker.
// - Sin NEON_METRICAS_URL arranca igual y avisa con jarvis_servicio_lectura_ok 0 (la alerta lo muestra).
// Para la presentación del curso se puede apuntar a una rama de Neon con datos ficticios: basta cambiar la URL.
import { readFileSync } from 'node:fs';
import http from 'node:http';
import pg from 'pg';

const URL_NEON = process.env.NEON_METRICAS_URL || '';
const INTERVALO = Math.max(300, Number(process.env.INTERVALO_SEGUNDOS) || 3600) * 1000;
const PUERTO = Number(process.env.PUERTO) || 9465;
const ORIGEN = process.env.METRICAS_ORIGEN || 'produccion'; // 'produccion' o 'demo' (rama con datos ficticios)
const ARCHIVO_RESPALDO = process.env.ARCHIVO_RESPALDO || '/estado-respaldo/respaldo.json';

const escapar = (v) => String(v).replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, ' ');
const numero = (v) => (Number.isFinite(Number(v)) ? Number(v) : 0);

// Una métrica de tipo gauge: filas [{ etiquetas: {…}, valor }].
function gauge(nombre, ayuda, filas) {
  const lineas = [`# HELP ${nombre} ${ayuda}`, `# TYPE ${nombre} gauge`];
  for (const { etiquetas = {}, valor } of filas) {
    const todas = { origen: ORIGEN, ...etiquetas };
    const texto = Object.entries(todas).map(([k, v]) => `${k}="${escapar(v)}"`).join(',');
    lineas.push(`${nombre}{${texto}} ${numero(valor)}`);
  }
  return lineas.join('\n');
}

let datos = ''; // las métricas de la última lectura buena
let estado = { ok: 0, ultima: 0, duracion: 0, errores: 0 };

async function leer() {
  const inicio = Date.now();
  const cliente = new pg.Client({
    connectionString: URL_NEON,
    // Neon siempre con TLS verificado; sin TLS solo el Postgres de prueba local (sslmode=disable en la URL).
    ssl: /sslmode=disable/.test(URL_NEON) ? false : { rejectUnauthorized: true },
    connectionTimeoutMillis: 30000, // Neon puede tardar unos segundos en despertar
    statement_timeout: 30000,
    application_name: 'jarvis-metricas',
  });
  await cliente.connect();
  try {
    const q = async (sql) => (await cliente.query(sql)).rows;
    // Una consulta tras otra: una sola conexión no hace dos a la vez (y son pocas filas).
    const consultas = [
      'select plan, estado, negocios from metricas.negocios',
      'select modulo, negocios from metricas.modulos',
      'select registradas, activas_hoy, activas_7d from metricas.personas',
      'select voz_minutos_hoy, voz_minutos_7d, tokens_7d from metricas.uso',
      'select estado, nivel, agente, encargos from metricas.encargos',
      'select enviados_24h, programados, dispositivos_con_avisos from metricas.recordatorios',
      'select estado, pagos from metricas.pagos',
      'select vinculadas, activas_24h from metricas.pcs',
    ];
    const r = [];
    for (const sql of consultas) r.push(await q(sql));
    const [negocios, modulos, [personas], [uso], encargos, [recordatorios], pagos, [pcs]] = r;
    datos = [
      gauge('jarvis_servicio_negocios', 'Negocios por plan y estado de la membresía.',
        negocios.map((f) => ({ etiquetas: { plan: f.plan, estado: f.estado }, valor: f.negocios }))),
      gauge('jarvis_servicio_modulo_negocios', 'Negocios con cada módulo prendido (ninguno: Uso personal).',
        modulos.map((f) => ({ etiquetas: { modulo: f.modulo }, valor: f.negocios }))),
      gauge('jarvis_servicio_personas', 'Personas registradas y activas (usaron a Jarvis).',
        ['registradas', 'activas_hoy', 'activas_7d'].map((t) => ({ etiquetas: { tipo: t }, valor: personas?.[t] }))),
      gauge('jarvis_servicio_voz_minutos', 'Minutos de voz con Gemini.',
        [{ etiquetas: { periodo: 'hoy' }, valor: uso?.voz_minutos_hoy }, { etiquetas: { periodo: '7d' }, valor: uso?.voz_minutos_7d }]),
      gauge('jarvis_servicio_tokens_7d', 'Tokens de Gemini en los últimos 7 días.', [{ valor: uso?.tokens_7d }]),
      gauge('jarvis_servicio_encargos_24h', 'Encargos de Jarvis en las últimas 24 horas, por estado, nivel y agente.',
        encargos.map((f) => ({ etiquetas: { estado: f.estado, nivel: f.nivel, agente: f.agente }, valor: f.encargos }))),
      gauge('jarvis_servicio_recordatorios', 'Recordatorios: avisos enviados en 24 horas y los que esperan su hora.',
        ['enviados_24h', 'programados'].map((t) => ({ etiquetas: { tipo: t }, valor: recordatorios?.[t] }))),
      gauge('jarvis_servicio_dispositivos_con_avisos', 'Dispositivos con los avisos activados.', [{ valor: recordatorios?.dispositivos_con_avisos }]),
      gauge('jarvis_servicio_pagos', 'Pagos por estado (reportado: espera confirmación del administrador).',
        pagos.map((f) => ({ etiquetas: { estado: f.estado }, valor: f.pagos }))),
      gauge('jarvis_servicio_pcs', 'PCs con la app de Jarvis: vinculadas y activas en 24 horas.',
        ['vinculadas', 'activas_24h'].map((t) => ({ etiquetas: { tipo: t }, valor: pcs?.[t] }))),
    ].join('\n');
  } finally {
    await cliente.end().catch(() => {});
  }
  return (Date.now() - inicio) / 1000;
}

async function ciclo() {
  if (!URL_NEON) {
    estado = { ...estado, ok: 0 };
    console.warn('[metricas] falta NEON_METRICAS_URL (.env.servicio): no se lee Neon');
    return;
  }
  for (let intento = 1; intento <= 2; intento++) {
    try {
      const duracion = await leer();
      estado = { ...estado, ok: 1, ultima: Date.now() / 1000, duracion };
      console.log(`[metricas] lectura ok en ${duracion.toFixed(1)} s`);
      return;
    } catch (e) {
      // Sin la URL en el log: solo el mensaje del error.
      console.warn(`[metricas] intento ${intento} falló: ${e.message}`);
      if (intento === 1) await new Promise((r) => setTimeout(r, 60000));
    }
  }
  estado = { ...estado, ok: 0, errores: estado.errores + 1 };
}

// El resultado del respaldo de cada noche (servicio-respaldo deja /estado/respaldo.json en un volumen compartido).
function respaldo() {
  let r;
  try {
    r = JSON.parse(readFileSync(ARCHIVO_RESPALDO, 'utf8'));
  } catch {
    return '';
  }
  return [
    gauge('jarvis_servicio_respaldo_ok', 'El último respaldo de Neon salió bien (1) o no (0).', [{ valor: r.ok }]),
    gauge('jarvis_servicio_respaldo_ultimo_ok_timestamp_segundos', 'Cuándo terminó el último respaldo bueno (segundos Unix).', [{ valor: r.ultimo_ok }]),
    gauge('jarvis_servicio_respaldo_bytes', 'Tamaño del último respaldo cifrado (bytes).', [{ valor: r.bytes }]),
  ].join('\n');
}

const propias = () => [
  respaldo(),
  gauge('jarvis_servicio_lectura_ok', 'La última lectura de Neon salió bien (1) o no (0).', [{ valor: estado.ok }]),
  gauge('jarvis_servicio_ultima_lectura_timestamp_segundos', 'Cuándo fue la última lectura buena (segundos Unix).', [{ valor: estado.ultima }]),
  gauge('jarvis_servicio_lectura_duracion_segundos', 'Cuánto tardó la última lectura buena (incluye despertar a Neon).', [{ valor: estado.duracion }]),
  gauge('jarvis_servicio_lecturas_fallidas', 'Lecturas fallidas desde que arrancó el colector.', [{ valor: estado.errores }]),
].join('\n');

http.createServer((req, res) => {
  if (req.url === '/metrics') {
    res.writeHead(200, { 'Content-Type': 'text/plain; version=0.0.4; charset=utf-8' });
    res.end(`${propias()}\n${datos}\n`);
  } else if (req.url === '/salud') {
    res.writeHead(200).end('ok');
  } else {
    res.writeHead(404).end();
  }
}).listen(PUERTO, '0.0.0.0', () => console.log(`[metricas] /metrics en el puerto ${PUERTO}, lee Neon cada ${INTERVALO / 60000} min`));

ciclo();
setInterval(ciclo, INTERVALO);
