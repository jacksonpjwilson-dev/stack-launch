import { randomBytes } from "node:crypto";
import { mkdir, readFile, writeFile, lstat, chmod } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { EncryptedStateFile } from "../backend/sync.mjs";
export const dataDirectory = () =>
  process.env.STACK_BMO_DATA_DIR ||
  path.join(os.homedir(), "Library", "Application Support", "Stack BMO Test");
export async function storage(directory = dataDirectory()) {
  const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  const relative = path.relative(repo, path.resolve(directory));
  if (
    !relative ||
    (!relative.startsWith(".." + path.sep) &&
      relative !== ".." &&
      !path.isAbsolute(relative))
  )
    throw Error("DATA_DIRECTORY_MUST_BE_OUTSIDE_REPOSITORY");
  await mkdir(directory, { recursive: true, mode: 0o700 });
  const stat = await lstat(directory);
  if (
    !stat.isDirectory() ||
    stat.isSymbolicLink() ||
    stat.uid !== process.getuid()
  )
    throw Error("UNSAFE_DATA_DIRECTORY");
  await chmod(directory, 0o700);
  const keyFile = path.join(directory, "encryption.key");
  try {
    await lstat(keyFile);
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
    for (const name of ["credentials.enc", "item.enc"]) {
      try {
        await lstat(path.join(directory, name));
        throw Error("KEY_MISSING_RESTORE_BACKUP");
      } catch (error) {
        if (error.code !== "ENOENT") throw error;
      }
    }
    await writeFile(keyFile, randomBytes(32), { mode: 0o600, flag: "wx" });
  }
  const keyStat = await lstat(keyFile);
  if (
    !keyStat.isFile() ||
    keyStat.isSymbolicLink() ||
    keyStat.uid !== process.getuid()
  )
    throw Error("UNSAFE_KEY_FILE");
  await chmod(keyFile, 0o600);
  const key = await readFile(keyFile);
  return {
    directory,
    credentials: new EncryptedStateFile(
      path.join(directory, "credentials.enc"),
      key,
    ),
    item: new EncryptedStateFile(path.join(directory, "item.enc"), key),
  };
}
