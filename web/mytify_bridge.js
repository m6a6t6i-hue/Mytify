(() => {
  // tools/web_bridge/bridge.js
  var sessionPromise;
  var progress = { done: 0, total: 0, name: "" };
  var activeJob = null;
  var migrationCancelled = false;
  var pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  async function session() {
    if (!sessionPromise) sessionPromise = fetch("/api/session", { cache: "no-store" }).then(async (response) => {
      if (!response.ok) throw new Error("Nie mo\u017Cna po\u0142\u0105czy\u0107 si\u0119 z katalogiem. Uruchom Mytify.exe.");
      return response.json();
    }).catch((error) => {
      sessionPromise = null;
      throw error;
    });
    return sessionPromise;
  }
  async function api(path, { method = "GET", body, headers = {}, raw = false } = {}) {
    const s = await session();
    const response = await fetch(s.base + path, {
      method,
      cache: "no-store",
      headers: {
        "X-Mytify-Token": s.token,
        ...body !== void 0 && !raw ? { "Content-Type": "application/json" } : {},
        ...headers
      },
      body: body === void 0 ? void 0 : raw ? body : JSON.stringify(body)
    });
    let value;
    try {
      value = await response.json();
    } catch {
      throw new Error("Katalog zwr\xF3ci\u0142 nieprawid\u0142ow\u0105 odpowied\u017A. Otw\xF3rz Mytify ponownie.");
    }
    if (!response.ok) throw new Error(value.error || `B\u0142\u0105d katalogu (${response.status}).`);
    return value;
  }
  async function scan(request) {
    const { job } = await api("/api/scan", { method: "POST", body: request });
    activeJob = job;
    if (migrationCancelled) await api("/api/jobs/" + encodeURIComponent(job), { method: "DELETE" });
    try {
      while (true) {
        const status = await api("/api/jobs/" + encodeURIComponent(job));
        progress = status.progress;
        if (status.finished) {
          if (status.error) throw new Error(status.error);
          return status.result;
        }
        await pause(160);
      }
    } finally {
      activeJob = null;
    }
  }
  async function pick(folder) {
    return (await api("/api/pick", { method: "POST", body: { folder } })).paths;
  }
  function legacyDatabase() {
    return new Promise((resolve) => {
      const request = indexedDB.open("mytify-library");
      request.onupgradeneeded = () => {
        request.transaction.abort();
        resolve(null);
      };
      request.onsuccess = () => {
        const db = request.result;
        if (!db.objectStoreNames.contains("tracks") || !db.objectStoreNames.contains("audio")) {
          db.close();
          resolve(null);
        } else resolve(db);
      };
      request.onerror = () => resolve(null);
    });
  }
  function legacyRead(db, store, id) {
    return new Promise((resolve, reject) => {
      const tx = db.transaction(store, "readonly");
      const request = id === void 0 ? tx.objectStore(store).getAll() : tx.objectStore(store).get(id);
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error);
    });
  }
  async function migrateLegacy() {
    const db = await legacyDatabase();
    if (!db) throw new Error("W tym profilu nie znaleziono biblioteki 0.1. Zamknij Mytify i uruchom MIGRACJA_0.1.cmd, u\u017Cywaj\u0105c tej samej przegl\u0105darki co wcze\u015Bniej.");
    const result = { added: 0, updated: 0, unchanged: 0, duplicates: 0, ignored: 0, missing: 0, offlineSources: 0, errors: [], cancelled: false };
    migrationCancelled = false;
    try {
      const tracks = await legacyRead(db, "tracks");
      for (let i = 0; i < tracks.length; i++) {
        if (migrationCancelled) {
          result.cancelled = true;
          break;
        }
        const track = tracks[i];
        progress = { done: i, total: tracks.length, name: track.fileName || track.title };
        try {
          const audio = await legacyRead(db, "audio", track.id);
          if (!audio?.blob) throw new Error("Brakuje kopii muzyki w starej bibliotece.");
          const report = await api("/api/migrate-v01", {
            method: "POST",
            raw: true,
            body: audio.blob,
            headers: {
              "Content-Type": "application/octet-stream",
              "X-Mytify-Hash": track.id,
              "X-Mytify-Filename": encodeURIComponent(track.fileName),
              "X-Mytify-Liked": String(!!track.liked)
            }
          });
          for (const key of ["added", "updated", "unchanged", "duplicates", "ignored"]) result[key] += report[key] || 0;
          result.errors.push(...report.errors);
        } catch (error) {
          result.errors.push(`${track.fileName}: ${error.message}`);
        }
      }
      progress = { done: tracks.length, total: tracks.length, name: "Przenoszenie zako\u0144czone" };
      return result;
    } finally {
      db.close();
    }
  }
  window.mytifyBridge = {
    async transfer(body) {
      return JSON.stringify(await api("/api/transfer", { method: "POST", body: JSON.parse(body) }));
    },
    async ingest(body) {
      const args = JSON.parse(body);
      return JSON.stringify(await api(args.action === "disc" ? "/api/metadata/disc" : "/api/ingest", { method: "POST", body: args }));
    },
    async audio(route, body) {
      if (!["state", "devices", "command"].includes(route)) throw new Error("Nieznana operacja odtwarzania.");
      return JSON.stringify(await api("/api/player/" + route, route === "command" ? { method: "POST", body: JSON.parse(body) } : {}));
    },
    async metadata(action, argsJson) {
      const args = JSON.parse(argsJson);
      if (action === "search") return JSON.stringify(await api("/api/metadata/search?album=" + encodeURIComponent(args.album) + "&artist=" + encodeURIComponent(args.artist)));
      if (action === "release" || action === "cover") return JSON.stringify(await api("/api/metadata/" + action + "/" + encodeURIComponent(args)));
      if (action === "edits" || action === "reset") return JSON.stringify(await api("/api/metadata/" + action, { method: "POST", body: args }));
      if (action === "chooseCover") {
        const file = await new Promise((resolve) => {
          const input = document.createElement("input");
          input.type = "file";
          input.accept = "image/png,image/jpeg";
          input.style.display = "none";
          document.body.append(input);
          const finish = (v) => {
            input.remove();
            resolve(v);
          };
          input.onchange = () => finish(input.files?.[0] || null);
          input.oncancel = () => finish(null);
          input.click();
        });
        if (!file) return JSON.stringify({ hash: null, uri: null });
        if (file.size > 8 * 1024 * 1024) throw new Error("Ok\u0142adka jest za du\u017Ca (maks. 8 MB).");
        return JSON.stringify(await api("/api/metadata/cover-file", { method: "POST", body: file, raw: true, headers: { "Content-Type": "application/octet-stream" } }));
      }
      throw new Error("Nieznana operacja metadanych.");
    },
    async load() {
      return JSON.stringify(await api("/api/library"));
    },
    async sources() {
      return JSON.stringify(await api("/api/sources"));
    },
    async search(query) {
      return JSON.stringify(await api("/api/search?q=" + encodeURIComponent(query)));
    },
    async importAudio(folder) {
      migrationCancelled = false;
      progress = { done: 0, total: 0, name: "Wybierz muzyk\u0119" };
      const paths = await pick(folder);
      return JSON.stringify(paths.length && !migrationCancelled ? await scan({ paths, folder }) : { cancelled: true });
    },
    async rescan(id) {
      migrationCancelled = false;
      return JSON.stringify(await scan({ sourceId: id || "all" }));
    },
    async relink(id) {
      migrationCancelled = false;
      const paths = await pick(true);
      if (!paths.length) return JSON.stringify({ cancelled: true });
      await api("/api/relink", { method: "POST", body: { id, path: paths[0] } });
      return JSON.stringify(await scan({ sourceId: id }));
    },
    async forgetSource(id) {
      await api("/api/sources/" + encodeURIComponent(id), { method: "DELETE" });
    },
    async cancel() {
      migrationCancelled = true;
      if (activeJob) await api("/api/jobs/" + encodeURIComponent(activeJob), { method: "DELETE" });
    },
    async migrate() {
      return JSON.stringify(await migrateLegacy());
    },
    progress() {
      return JSON.stringify(progress);
    },
    async like(id, liked) {
      await api("/api/like/" + encodeURIComponent(id), { method: "POST", body: { liked } });
    },
    async remove(id) {
      await api("/api/tracks/" + encodeURIComponent(id), { method: "DELETE" });
    },
    async playableUri(id) {
      const s = await session();
      return s.base + "/api/audio/" + encodeURIComponent(id) + "?token=" + encodeURIComponent(s.token);
    }
  };
})();
