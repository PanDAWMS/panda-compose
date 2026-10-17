"""
DockerSubmitter — Harvester submitter plugin that runs PanDA jobs inside Docker containers.

Each worker maps to one detached container. The image is resolved in priority order:
  1. job.jobParams["container_name"] — per-job image set by the submitter via
     job.container_name (mirrors PanDA's production container_name field); any
     leading "docker://" prefix is stripped for Docker SDK compatibility.
  2. containerImage queue config key — the site-level default (e.g. "alpine:latest").

The Docker socket path is configurable via the dockerSocket queue config key.
Job command is derived from jobSpec.jobParams fields "transformation" (executable)
and "jobPars" (argument string).

Each worker gets a per-worker output directory bind-mounted into the container
at /output. The user exec is wrapped so that it runs inside /output as the cwd;
any files the transformation writes to `.` land on the host and are visible to
the RucioStager after the container exits.

Input files (from jobParams["inFiles"], scope from jobParams["scopeIn"]) are
staged in by symlinking their on-RSE PFNs into the same /output directory
BEFORE the container starts. This works because the local dev RSE
(MOCK-POSIX) uses the deterministic `hash` layout under /tmp/rucio_rse which
is bind-mounted read-only into the worker container. The user's exec can then
reference the input LFN as a relative path.

The prun source sandbox (jobPars "-a jobO.<uuid>.tar.gz", uploaded by
PrunScript to the PanDA cache at pandaCacheBase) is fetched and extracted
into the same /output directory before the container starts, mirroring what
the runGen transformation does on a real WN. Without it the user's "-p"
exec (e.g. "./payload.sh") has nothing to run and the container exits 127.

Queue config example:

    "submitter": {
        "name": "DockerSubmitter",
        "module": "docker_submitter",
        "containerImage": "alpine:latest",
        "dockerSocket": "unix:///var/run/docker.sock",
        "outputBaseDir": "/tmp/harvester_output",
        "rseBaseDir": "/tmp/rucio_rse",
        "pandaCacheBase": "http://panda-server:80/cache"
    }

Design notes (why the sandbox fetch lives here, and what it reimplements):

- On a real worker node the pilot executes the runGen transformation
  (/var/trf/user/runGen-XX-XX-XX), which downloads the "-a" archive from
  <sourceURL>/cache/, extracts it, chmods the exec, and runs the "-p"
  string (runGen.py:310-324, 565). This plugin has no pilot, so it
  reimplements only that core slice:
    _get_exec_str      <- runGen's urllib.unquote("-p")
    _stage_in_sandbox  <- runGen's "getting sandbox" fetch+extract step
    _chmod_exec_script <- runGen's "chmod +x just in case" step
  ATLAS-specific runGen machinery (Athena/CMake release setup, the
  "libraries" tarball, the trf.<uuid>.py wrapper, --fileToLoad/--fileToSave)
  is deliberately not reimplemented.

- Harvester already ships a sandbox-fetch pipeline: AuxExtractor parses
  "-a"/"-i" and --sourceURL out of jobPars and AnalysisAuxPreparator
  HTTP-GETs the archive. It is not used here because (a) these compose
  queues configure DummyPreparator and no extractor at all, (b)
  AuxExtractor derives the URL from jobPars' --sourceURL, which
  PrunScript scopes to the submission client's own PanDA URL
  (http://localhost:25080 on the submitter host) -- unreachable from the
  harvester container -- so a queue-config pandaCacheBase is used
  instead, and (c) the preparator would leave the archive unextracted on
  a local access path rather than in the worker's /output.

- Only "-a" is handled, not "-i": AuxExtractor switches between them on
  prodSourceLabel=="user", but these queues run prodSourceLabel=test and
  only ever receive prun-style submissions, whose source sandbox is "-a".

- Stage-in is best-effort: a missing or unreachable sandbox logs a
  warning and the job fails at exec time, matching the pre-fix failure
  mode. Retry semantics stay with harvester (maxSubmissionAttempts in
  the queue config) rather than duplicating AnalysisAuxPreparator's
  per-file retry loop.
"""

import hashlib
import os
import shlex
import stat
import tarfile
import tempfile
import urllib.request
import uuid

import docker as docker_module
from pandaharvester.harvestercore import core_utils
from pandaharvester.harvestercore.plugin_base import PluginBase

baseLogger = core_utils.setup_logger("docker_submitter")


def _rucio_deterministic_pfn(scope, name):
    """Compute the deterministic PFN path (relative to the RSE root) that Rucio
    uses for the given `scope:name`.  Matches Rucio's default
    `RSEDeterministicTranslation` with the `hash` algorithm:

        <scope>/<md5[0:2]>/<md5[2:4]>/<name>
    """
    digest = hashlib.md5(f"{scope}:{name}".encode("utf-8")).hexdigest()
    return os.path.join(scope, digest[0:2], digest[2:4], name)


class DockerSubmitter(PluginBase):
    def __init__(self, **kwarg):
        self.containerImage = "alpine:latest"
        self.dockerSocket = "unix:///var/run/docker.sock"
        # Host-side directory where per-worker output subdirs are created. Must
        # also be mounted into the harvester container at the same path so that
        # RucioStager can read the files back.
        self.outputBaseDir = "/tmp/harvester_output"
        # Host-side directory that holds the MOCK-POSIX RSE bytes. Bind-mounted
        # RO into the worker container so the input LFNs (as symlinks) resolve.
        self.rseBaseDir = "/tmp/rucio_rse"
        # Base URL of the PanDA cache (httpd Alias /cache/ -> pandacache/).
        # Used to fetch the prun sandbox referenced by the job's "-a <name>"
        # jobPars entry. Must be a URL reachable from the harvester container;
        # the default follows the compose-internal panda-server hostname.
        self.pandaCacheBase = "http://panda-server:80/cache"
        PluginBase.__init__(self, **kwarg)

    def _resolve_image(self, job, wLog):
        """Return the Docker image to use for this job."""
        per_job = job.jobParams.get("container_name", "").strip() if job else ""
        if per_job:
            image = per_job.removeprefix("docker://")
            wLog.debug(f"using per-job container image={image} (from container_name)")
        else:
            image = self.containerImage
            wLog.debug(f"using queue default container image={image}")
        return image

    def _build_command(self, job, wLog):
        """Return the argv the container should run, plus the user's exec_str.

        The exec_str is what the user asked for (e.g. "echo hello > out.txt");
        argv is what actually runs in the container (typically ["sh", "-c",
        "cd /output && <exec_str>"]).

        Placeholders in the user's exec are expanded to real filenames:
        - `%IN` — comma-separated list of input LFN basenames (as seen inside
          the container, since we symlink each input LFN into /output).
        - `%IN[0]`, `%IN[1]`, ... — individual input LFNs.
        - `%OUT` is intentionally NOT expanded (the ATLAS convention needs
          extra bookkeeping and prun handles it upstream via `--outputs`).
        """
        if not job:
            return ["sh", "-c", "echo 'no job spec available'"], ""

        exec_str = self._get_exec_str(job, wLog)

        # Expand %IN placeholders using the same LFN list we symlinked in.
        in_files_str = (job.jobParams.get("inFiles") or "").strip()
        in_lfns = [x for x in in_files_str.split(",") if x]
        if in_lfns:
            # Indexed forms first so they're not swallowed by the generic %IN.
            for i, lfn in enumerate(in_lfns):
                exec_str = exec_str.replace(f"%IN[{i}]", lfn)
            exec_str = exec_str.replace("%IN", ",".join(in_lfns))
            wLog.debug(f"expanded %IN placeholders; final exec_str={exec_str!r}")

        # Wrap so the user command runs inside /output. Any file it writes to
        # `.` (or bare "out.txt") lands in the shared volume.
        wrapped = f"cd /output && {{ {exec_str}; }}"
        return ["sh", "-c", wrapped], exec_str

    def _stage_in_inputs(self, job, worker_output_host, wLog):
        """Symlink each input LFN's on-RSE bytes into the worker's output dir.

        Uses jobParams["inFiles"] (comma-separated LFNs) and
        jobParams["scopeIn"] (single scope for now — good enough for the local
        dev stack; JEDI may in future emit "scope1,scope2" for multi-scope
        inputs, in which case we split & zip).

        On the host, the RSE bytes live at
            <rseBaseDir>/<scope>/<hh>/<hh>/<lfn>
        Symlinks are placed at
            <worker_output_host>/<lfn>
        so the container sees them at /output/<lfn>.
        """
        if not job:
            return
        params = job.jobParams or {}
        in_files_str = params.get("inFiles") or ""
        if not in_files_str:
            return
        lfns = [x for x in in_files_str.split(",") if x]
        scopes_raw = params.get("scopeIn") or ""
        scopes = [x for x in scopes_raw.split(",") if x]
        # If we got fewer scopes than LFNs, broadcast the first (or default).
        default_scope = scopes[0] if scopes else "mock"
        scope_for = lambda i: scopes[i] if i < len(scopes) else default_scope

        for i, lfn in enumerate(lfns):
            scope = scope_for(i)
            pfn_rel = _rucio_deterministic_pfn(scope, lfn)
            src = os.path.join(self.rseBaseDir, pfn_rel)
            dst = os.path.join(worker_output_host, lfn)
            if not os.path.exists(src):
                wLog.warning(f"input LFN {scope}:{lfn} not found on RSE at {src}; skipping symlink")
                continue
            if os.path.lexists(dst):
                try:
                    os.remove(dst)
                except OSError:
                    pass
            try:
                os.symlink(src, dst)
                wLog.debug(f"staged input {scope}:{lfn} -> {dst} (via symlink to {src})")
            except OSError as exc:
                wLog.warning(f"could not symlink {src} to {dst}: {exc}")

    def _get_exec_str(self, job, wLog):
        """Return the user's exec string for this job.

        If the task refiner assigned an ATLAS-style URL transformation
        (http://panda-server:85/trf/user/runGen-XX-XX-XX), the container has no
        way to fetch and execute it. Extract the user's actual exec string
        from the -p flag of jobPars (URL-encoded, per the runGen convention),
        mirroring runGen.py's ``jobParams = urllib.unquote(opt -p)``.

        Otherwise (simple transformation, e.g. "sh") the exec is
        <transformation> <jobPars>.
        """
        if not job:
            return "echo 'no job spec available'"
        transformation = job.jobParams.get("transformation", "sh")
        job_pars = job.jobParams.get("jobPars", "")

        if transformation.startswith(("http://", "https://")):
            from urllib.parse import unquote_plus

            exec_str = ""
            parts = shlex.split(job_pars) if job_pars else []
            for i, p in enumerate(parts):
                if p == "-p" and i + 1 < len(parts):
                    exec_str = unquote_plus(parts[i + 1])
                    break
            if not exec_str:
                exec_str = "echo 'no exec string found in jobPars'"
            wLog.debug(f"URL transformation; extracted exec_str={exec_str!r}")
            return exec_str

        if job_pars:
            # Reconstruct a shell string: <trans> <arg1> <arg2> ...
            return transformation + " " + job_pars
        return transformation

    def _get_sandbox_name(self, job, wLog):
        """Return the prun sandbox archive name from the job's "-a <name>"
        jobPars entry, or None when the job carries no sandbox.

        PrunScript bakes the uploaded source archive into jobParameters as
        "-a jobO.<uuid>.tar.gz" (see PrunScript ~line 2239). On a real WN the
        runGen transformation downloads it from ${SURL}/cache/ and extracts it
        before exec'ing the user's "-p" payload. This submitter runs "-p"
        directly, so it must do the download+extract itself.
        """
        if not job:
            return None
        job_pars = (job.jobParams or {}).get("jobPars", "") or ""
        try:
            parts = shlex.split(job_pars)
        except ValueError:
            wLog.warning(f"could not shlex-split jobPars for sandbox lookup: {job_pars!r}")
            return None
        for i, p in enumerate(parts):
            if p == "-a" and i + 1 < len(parts):
                return parts[i + 1]
        return None

    def _stage_in_sandbox(self, job, worker_output_host, wLog):
        """Fetch the prun sandbox from the PanDA cache and extract it into the
        worker's output dir so the container sees its files under /output.

        Best-effort: a missing/unreachable sandbox logs a warning and leaves
        the job to fail at exec time (same behaviour as before this existed).
        """
        archive_name = self._get_sandbox_name(job, wLog)
        if not archive_name:
            wLog.debug("no -a sandbox in jobPars; skipping sandbox stage-in")
            return
        # Only accept a bare filename: the value comes from the task's
        # jobParameters and must never turn into an arbitrary URL/path fetch.
        if "/" in archive_name or archive_name.startswith(("http://", "https://")):
            wLog.warning(f"unexpected sandbox name {archive_name!r}; skipping sandbox stage-in")
            return
        url = f"{self.pandaCacheBase.rstrip('/')}/{archive_name}"
        tmp_path = None
        try:
            wLog.debug(f"fetching sandbox {url}")
            with tempfile.NamedTemporaryFile(suffix=".tar.gz", delete=False) as tmp:
                tmp_path = tmp.name
                with urllib.request.urlopen(url, timeout=60) as resp:
                    tmp.write(resp.read())
            with tarfile.open(tmp_path) as tar:
                # filter= guards against path traversal outside the dest
                # (Python >= 3.12 default; explicit for older versions).
                try:
                    tar.extractall(worker_output_host, filter="data")
                except TypeError:
                    # Python < 3.11.4 has no filter kwarg
                    tar.extractall(worker_output_host)
            wLog.debug(f"extracted sandbox {archive_name} into {worker_output_host}")
            # runGen parity: make sure the exec is executable even if the
            # archive was built on a filesystem that strips mode bits.
            self._chmod_exec_script(job, worker_output_host, wLog)
        except Exception as exc:
            wLog.warning(f"failed to stage in sandbox {archive_name} from {url}: {exc}")
        finally:
            if tmp_path:
                try:
                    os.unlink(tmp_path)
                except Exception:
                    pass

    def _chmod_exec_script(self, job, worker_output_host, wLog):
        """Ensure the exec named by "-p" is executable after extraction.

        runGen.py does ``chmod +x`` on the script "just in case" before
        exec (runGen.py:565). Archives built on filesystems that do not
        preserve exec bits would otherwise fail with "Permission denied"
        even though the file exists. Best-effort, mirrors runGen's
        behaviour: a missing file is ignored (the exec itself will report
        it), and the first token of "-p" is only chmodded when it is a
        plain relative path (runGen chmods ``jobParams.split()[0]``
        unconditionally; we skip absolute paths, URLs, and command
        separators to avoid touching anything outside /output).
        """
        exec_str = self._get_exec_str(job, wLog)
        tokens = exec_str.split()
        if not tokens:
            return
        script = tokens[0]
        # Skip tokens that cannot be a sandbox file: absolute paths and
        # URLs point outside /output, "-*" are flags, "*=*" are variable
        # assignments, and builtins (echo, sh, ...) are not files at all
        # (caught by the isfile check below).
        if script.startswith(("/", "-")) or "://" in script or "=" in script:
            return
        # Normalize "./payload.sh" -> "payload.sh"; refuse traversal.
        script = os.path.normpath(script)
        if script == "." or script.startswith(".."):
            return
        path = os.path.join(worker_output_host, script)
        if not os.path.isfile(path):
            # The exec may reference a file that the payload itself will
            # generate, or an interpreter (e.g. "sh script.sh"); nothing
            # to do.
            return
        try:
            os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
            wLog.debug(f"chmod +x {path} (runGen parity)")
        except OSError as exc:
            wLog.warning(f"could not chmod +x {path}: {exc}")

    def submit_workers(self, workspec_list):
        tmpLog = self.make_logger(baseLogger, method_name="submit_workers")
        tmpLog.debug(f"start nWorkers={len(workspec_list)}")

        try:
            client = docker_module.DockerClient(base_url=self.dockerSocket)
        except Exception as exc:
            err = f"Failed to connect to Docker daemon at {self.dockerSocket}: {exc}"
            tmpLog.error(err)
            return [(False, err)] * len(workspec_list)

        retList = []
        for workSpec in workspec_list:
            wLog = self.make_logger(baseLogger, f"workerID={workSpec.workerID}", method_name="submit_workers")
            try:
                jobspec_list = workSpec.get_jobspec_list()
                job = jobspec_list[0] if jobspec_list else None

                command, exec_str = self._build_command(job, wLog)
                image = self._resolve_image(job, wLog)

                # Per-worker output directory on the host. Both this container's
                # process (via bind mount) and the harvester container (which
                # also mounts outputBaseDir) can read/write it.
                worker_output_host = os.path.join(self.outputBaseDir, f"worker-{workSpec.workerID}")
                os.makedirs(worker_output_host, exist_ok=True)
                os.chmod(worker_output_host, 0o777)  # let non-root user containers write

                # Stage inputs BEFORE launching the container.
                self._stage_in_inputs(job, worker_output_host, wLog)
                # Stage the prun sandbox (-a jobO.*.tar.gz) the same way, so
                # the user's "./payload.sh" (from -p) actually exists in /output.
                self._stage_in_sandbox(job, worker_output_host, wLog)

                # Record the output dir on the workspec for the stager. workAttributes
                # is a JSON blob persisted with the worker row.
                try:
                    workSpec.set_work_params({"outputHostDir": worker_output_host})
                except Exception:
                    pass

                container_name = f"harvester-worker-{workSpec.workerID}-{uuid.uuid4().hex[:8]}"

                # Always mount the per-worker output dir at /output. Optionally
                # add a read-only RSE mount so that the input symlinks placed
                # by _stage_in_inputs resolve inside the container. The mount
                # is skipped when rseBaseDir does not exist on the host, so
                # panda-compose still starts cleanly on a plain (no-Rucio)
                # install.
                volumes = {
                    worker_output_host: {"bind": "/output", "mode": "rw"},
                }
                if os.path.isdir(self.rseBaseDir):
                    volumes[self.rseBaseDir] = {"bind": self.rseBaseDir, "mode": "ro"}
                    rse_mount_desc = f"rse_mount={self.rseBaseDir}:{self.rseBaseDir}:ro"
                else:
                    rse_mount_desc = f"rse_mount=disabled ({self.rseBaseDir} not present)"
                wLog.debug(
                    f"running container image={image} command={command} "
                    f"output_mount={worker_output_host}:/output {rse_mount_desc}"
                )

                container = client.containers.run(
                    image,
                    command=command,
                    name=container_name,
                    detach=True,
                    remove=False,
                    volumes=volumes,
                    working_dir="/output",
                )
                workSpec.batchID = container.id
                wLog.debug(f"started container id={container.id[:12]}")
                retList.append((True, ""))
            except Exception as exc:
                err = f"Failed to start container for workerID={workSpec.workerID}: {exc}"
                wLog.error(err)
                retList.append((False, err))

        try:
            client.close()
        except Exception:
            pass

        tmpLog.debug("done")
        return retList
