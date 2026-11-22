// Prepara los secretos del respaldo (se corre una vez en la laptop del administrador, desde jarvis-app/; lo llama
// scripts/desplegar-respaldo.ps1). Sin mostrar nunca un secreto en pantalla:
//   1) La contraseña del rol jarvis_respaldo (migración 020): deja el SQL en %USERPROFILE%\.jarvis\respaldo-rol.sql
//      (fuera de git; se pega en el SQL Editor de Neon y se puede borrar).
//   2) El par de llaves de cifrado (age), con Docker: la PRIVADA queda solo en %USERPROFILE%\.jarvis\respaldo-llave.txt
//      (nunca va a la VM ni a la nube: sin ella nadie abre los respaldos; si se pierde, los respaldos no se pueden abrir).
//      La pública va a la VM.
//   3) La conexión y la llave pública para la VM en %USERPROFILE%\.jarvis\servicio-respaldo.env (el despliegue le
//      suma el bucket y la cuenta de servicio, y la copia a la VM como /opt/jarvis-app/.env.respaldo).
import { spawnSync } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const raiz = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const envLocal = path.join(raiz, 'panel', '.env.local');
const secretos = path.join(os.homedir(), '.jarvis');
const archivoRol = path.join(secretos, 'respaldo-rol.sql');
const archivoLlave = path.join(secretos, 'respaldo-llave.txt');
const archivoEnv = path.join(secretos, 'servicio-respaldo.env');

if (existsSync(archivoEnv) && !process.argv.includes('--rotar')) {
  console.log(`Ya existe ${archivoEnv}. Para cambiar la contraseña: --rotar (la llave de cifrado no se cambia).`);
  process.exit(0);
}

const local = existsSync(envLocal) ? readFileSync(envLocal, 'utf8') : '';
const dataApi = local.match(/^NEXT_PUBLIC_NEON_DATA_API_URL=(.+)$/m)?.[1]?.trim();
// pg_dump va directo al endpoint (sin el pooler), como recomienda Neon para copias.
const host = dataApi && new URL(dataApi).hostname.replace('.apirest.', '.');
if (!host || host === new URL(dataApi).hostname) throw new Error('No encontré NEXT_PUBLIC_NEON_DATA_API_URL en panel/.env.local');

mkdirSync(secretos, { recursive: true });

// La llave de cifrado se crea una sola vez: si se cambiara, los respaldos viejos seguirían necesitando la anterior.
if (!existsSync(archivoLlave)) {
  // Con la misma imagen del respaldo (trae age), armada aquí desde servicio-respaldo/.
  const imagen = 'jarvis-servicio-respaldo:local';
  const b = spawnSync('docker', ['build', '-q', '-t', imagen, path.join(raiz, 'servicio-respaldo')], { encoding: 'utf8' });
  if (b.status !== 0) throw new Error('No se pudo armar la imagen del respaldo con Docker (¿Docker está abierto?)');
  const r = spawnSync('docker', ['run', '--rm', imagen, 'age-keygen'], { encoding: 'utf8' });
  if (r.status !== 0 || !r.stdout.includes('AGE-SECRET-KEY-')) throw new Error('No se pudo crear la llave con Docker (¿Docker está abierto?)');
  writeFileSync(archivoLlave, r.stdout, { mode: 0o600 });
}
const publica = readFileSync(archivoLlave, 'utf8').match(/public key: (age1[0-9a-z]+)/)?.[1];
if (!publica) throw new Error(`No encontré la llave pública en ${archivoLlave}`);

const clave = randomBytes(32).toString('base64url');
writeFileSync(archivoRol, `-- Pegar en el SQL Editor de Neon (jarvis-servicio), DESPUÉS de la migración 020. Después se puede borrar este archivo.\nalter role jarvis_respaldo with login password '${clave}';\n`);
writeFileSync(archivoEnv, [
  '# Respaldo de Jarvis como servicio (servicio-respaldo/). En la VM: /opt/jarvis-app/.env.respaldo, permisos 600.',
  // verify-full con los certificados del sistema: cifrado y comprobando que de verdad es Neon.
  `NEON_RESPALDO_URL=postgresql://jarvis_respaldo:${clave}@${host}/neondb?sslmode=verify-full&sslrootcert=system`,
  `RESPALDO_LLAVE_PUBLICA=${publica}`,
  '',
].join('\n'), { mode: 0o600 });

console.log(`SQL para Neon: ${archivoRol}`);
console.log(`Llave privada (no sale de esta laptop): ${archivoLlave}`);
console.log(`Para la VM: ${archivoEnv}`);
