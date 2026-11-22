// Prepara el secreto del colector de métricas (se corre una vez en la laptop del administrador, desde jarvis-app/):
//   node servicio-metricas/preparar.mjs
// Sin mostrar nunca la contraseña en pantalla:
//   1) Genera la contraseña del rol jarvis_metricas (migración 019) y deja el SQL para ponérsela en
//      %USERPROFILE%\.jarvis\metricas-rol.sql (fuera de git; se pega en el SQL Editor de Neon y se puede borrar).
//   2) Deja la conexión para la VM en %USERPROFILE%\.jarvis\servicio-metricas.env (fuera de git). Se copia a la VM
//      como /opt/jarvis-app/.env.servicio (permisos 600) y se puede borrar de la laptop.
// La dirección de Neon sale de la de la Data API, que es pública (mismo endpoint, con el pooler).
import { randomBytes } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const raiz = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const envLocal = path.join(raiz, 'panel', '.env.local');
const secretos = path.join(os.homedir(), '.jarvis');
const archivoRol = path.join(secretos, 'metricas-rol.sql');
const archivoEnv = path.join(secretos, 'servicio-metricas.env');

if (existsSync(archivoEnv) && !process.argv.includes('--rotar')) {
  console.log(`Ya existe ${archivoEnv}. Para cambiar la contraseña: --rotar`);
  process.exit(0);
}

const local = existsSync(envLocal) ? readFileSync(envLocal, 'utf8') : '';
const dataApi = local.match(/^NEXT_PUBLIC_NEON_DATA_API_URL=(.+)$/m)?.[1]?.trim();
const host = dataApi && new URL(dataApi).hostname.replace('.apirest.', '-pooler.');
if (!host || !host.includes('-pooler.')) throw new Error('No encontré NEXT_PUBLIC_NEON_DATA_API_URL en panel/.env.local');

const clave = randomBytes(32).toString('base64url');
mkdirSync(secretos, { recursive: true });
writeFileSync(archivoRol, `-- Pegar en el SQL Editor de Neon (jarvis-servicio), DESPUÉS de la migración 019. Después se puede borrar este archivo.\nalter role jarvis_metricas with login password '${clave}';\n`);
writeFileSync(archivoEnv, [
  '# Colector de métricas de Jarvis como servicio (servicio-metricas/). En la VM: /opt/jarvis-app/.env.servicio, permisos 600.',
  `NEON_METRICAS_URL=postgresql://jarvis_metricas:${clave}@${host}/neondb?sslmode=require`,
  '# produccion o demo (si NEON_METRICAS_URL apunta a una rama de Neon con datos ficticios)',
  'METRICAS_ORIGEN=produccion',
  '',
].join('\n'));

console.log(`SQL para Neon: ${archivoRol}`);
console.log(`Conexión para la VM: ${archivoEnv}`);
