(function () {
  "use strict";

  var STALE_SECONDS = 26 * 3600;
  var state = { jobs: [], totals: {} };

  var el = {
    globalDot: document.getElementById("globalDot"),
    lastRefresh: document.getElementById("lastRefresh"),
    autoRefresh: document.getElementById("autoRefresh"),
    refreshBtn: document.getElementById("refreshBtn"),
    kpiTotal: document.getElementById("kpiTotal"),
    kpiOk: document.getElementById("kpiOk"),
    kpiErr: document.getElementById("kpiErr"),
    kpiFiles: document.getElementById("kpiFiles"),
    searchInput: document.getElementById("searchInput"),
    statusFilter: document.getElementById("statusFilter"),
    jobsBody: document.getElementById("jobsTableBody"),
    modal: document.getElementById("detailModal"),
    modalTitle: document.getElementById("modalTitle"),
    modalSubtitle: document.getElementById("modalSubtitle"),
    modalError: document.getElementById("modalError"),
    modalMeta: document.getElementById("modalMeta"),
    modalFilesBody: document.getElementById("modalFilesBody"),
    closeModalBtn: document.getElementById("closeModalBtn")
  };

  function formatBytes(bytes) {
    var num = Number(bytes) || 0;
    if (num < 1024) return num + " B";
    var units = ["KB", "MB", "GB", "TB"];
    var idx = -1;
    do {
      num /= 1024;
      idx++;
    } while (num >= 1024 && idx < units.length - 1);
    return num.toFixed(1) + " " + units[idx];
  }

  function isStale(job) {
    if (!job.finished_at_epoch) return true;
    var nowEpoch = Math.floor(Date.now() / 1000);
    return (nowEpoch - Number(job.finished_at_epoch)) > STALE_SECONDS;
  }

  function effectiveStatus(job) {
    if (job.status !== "OK") return "ERROR";
    if (isStale(job)) return "STALE";
    return "OK";
  }

  function createCell(text, className) {
    var td = document.createElement("td");
    if (className) td.className = className;
    td.textContent = text;
    return td;
  }

  function createBadge(status) {
    var span = document.createElement("span");
    span.className = "badge " + (status === "OK" ? "badge-ok" : status === "STALE" ? "badge-warn" : "badge-err");
    span.textContent = status;
    return span;
  }

  function renderTable() {
    var query = (el.searchInput.value || "").toLowerCase();
    var filter = el.statusFilter.value;
    el.jobsBody.textContent = "";

    var filtered = state.jobs.filter(function (job) {
      var st = effectiveStatus(job);
      if (filter !== "ALL" && st !== filter) return false;
      if (!query) return true;
      var hay = [job.job_id, job.owner, job.remote_host, job.description].join(" ").toLowerCase();
      return hay.indexOf(query) !== -1;
    });

    if (filtered.length === 0) {
      var trEmpty = document.createElement("tr");
      var tdEmpty = createCell("Brak zadań pasujących do filtra.", "empty");
      tdEmpty.colSpan = 8;
      trEmpty.appendChild(tdEmpty);
      el.jobsBody.appendChild(trEmpty);
      return;
    }

    filtered.forEach(function (job) {
      var st = effectiveStatus(job);
      var tr = document.createElement("tr");
      tr.className = "clickable";
      tr.addEventListener("click", function () { openJobDetails(job.job_id); });

      tr.appendChild(createCell(job.job_id || "—", "mono"));
      tr.appendChild(createCell(job.owner || "—"));
      tr.appendChild(createCell((job.protocol || "").toUpperCase() + " → " + (job.remote_host || "") + ":" + (job.remote_dir || ""), "mono"));
      tr.appendChild(createCell(job.finished_at || "—", "mono"));
      tr.appendChild(createCell((job.duration_sec != null ? job.duration_sec : "—") + " s"));
      tr.appendChild(createCell(String(job.files_transferred || 0) + " / " + String(job.files_total || 0)));
      tr.appendChild(createCell(formatBytes(job.bytes_transferred)));

      var tdStatus = document.createElement("td");
      tdStatus.appendChild(createBadge(st));
      tr.appendChild(tdStatus);
      el.jobsBody.appendChild(tr);
    });
  }

  function renderSummary(data) {
    state.jobs = data.jobs || [];
    state.totals = data.totals || {};

    var errCount = 0;
    var okCount = 0;
    state.jobs.forEach(function (j) {
      if (effectiveStatus(j) === "OK") okCount++;
      else errCount++;
    });

    el.kpiTotal.textContent = String(state.jobs.length);
    el.kpiOk.textContent = String(okCount);
    el.kpiErr.textContent = String(errCount);
    el.kpiFiles.textContent = String(state.totals.files_transferred || 0) + " / " + formatBytes(state.totals.bytes_transferred || 0);

    el.globalDot.className = "brand-dot " + (errCount > 0 ? "err" : state.jobs.length > 0 ? "ok" : "warn");
    el.lastRefresh.textContent = "Aktualizacja: " + new Date().toLocaleTimeString("pl-PL");
    renderTable();
  }

  function openJobDetails(jobId) {
    fetch("/api/jobs/" + encodeURIComponent(jobId) + ".json?_=" + Date.now())
      .then(function (r) {
        if (!r.ok) throw new Error("HTTP " + r.status);
        return r.json();
      })
      .then(function (job) {
        el.modalTitle.textContent = job.job_id;
        el.modalSubtitle.textContent = job.description || "";

        if (job.error_message) {
          el.modalError.textContent = "Błąd: " + job.error_message;
          el.modalError.hidden = false;
        } else {
          el.modalError.hidden = true;
        }

        el.modalMeta.textContent = "";
        [
          ["Właściciel", job.owner],
          ["Protokół", (job.protocol || "").toUpperCase()],
          ["Host docelowy", job.remote_host + ":" + job.remote_dir],
          ["Start", job.started_at],
          ["Koniec", job.finished_at],
          ["Kod wyjścia", String(job.exit_code)]
        ].forEach(function (pair) {
          var div = document.createElement("div");
          var b = document.createElement("strong");
          b.textContent = pair[0] + ": ";
          var span = document.createElement("span");
          span.textContent = pair[1] || "—";
          div.appendChild(b);
          div.appendChild(span);
          el.modalMeta.appendChild(div);
        });

        el.modalFilesBody.textContent = "";
        var files = job.files || [];
        if (files.length === 0) {
          var tr = document.createElement("tr");
          var td = createCell("Brak plików w tym uruchomieniu.", "empty");
          td.colSpan = 4;
          tr.appendChild(td);
          el.modalFilesBody.appendChild(tr);
        } else {
          files.forEach(function (f) {
            var tr = document.createElement("tr");
            tr.appendChild(createCell(f.name, "mono"));
            tr.appendChild(createCell(formatBytes(f.size_bytes)));
            tr.appendChild(createCell(f.sha256 || "—", "mono"));
            var tdSt = document.createElement("td");
            tdSt.appendChild(createBadge(f.status === "transferred" ? "OK" : "ERROR"));
            tr.appendChild(tdSt);
            el.modalFilesBody.appendChild(tr);
          });
        }
        el.modal.hidden = false;
      })
      .catch(function (err) {
        el.modalTitle.textContent = jobId;
        el.modalError.textContent = "Nie udało się pobrać szczegółów: " + err.message;
        el.modalError.hidden = false;
        el.modal.hidden = false;
      });
  }

  function loadSummary() {
    fetch("/api/summary.json?_=" + Date.now())
      .then(function (r) {
        if (!r.ok) throw new Error("HTTP " + r.status);
        return r.json();
      })
      .then(renderSummary)
      .catch(function (err) {
        el.globalDot.className = "brand-dot err";
        el.lastRefresh.textContent = "Błąd odczytu API: " + err.message;
      });
  }

  el.refreshBtn.addEventListener("click", loadSummary);
  el.searchInput.addEventListener("input", renderTable);
  el.statusFilter.addEventListener("change", renderTable);
  el.closeModalBtn.addEventListener("click", function () { el.modal.hidden = true; });
  el.modal.addEventListener("click", function (e) { if (e.target === el.modal) el.modal.hidden = true; });

  setInterval(function () {
    if (el.autoRefresh.checked) loadSummary();
  }, 30000);

  loadSummary();
})();
