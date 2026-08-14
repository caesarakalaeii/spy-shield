{
  # Keep this line accurate and one line long: `nix flake metadata` prints it,
  # and it is the first thing a cold agent learns about the repo.
  description = "spy-shield -- Quart web app plus a polling daemon that watches Discord server IDs for tracker activity. Run `nix flake show` for the command map.";

  # nixpkgs is the only input, on purpose.
  #
  # flake-utils would buy exactly one thing here -- eachDefaultSystem -- which is
  # the three-line genAttrs below. In exchange it costs a second lock node in
  # every repo (flake-utils transitively pulls `systems`, so really two), a
  # second upstream that can break one repo and not the other forty, and a
  # hardcoded system list this repo cannot edit. That list is currently broken:
  # it still contains x86_64-darwin, which now throws (see `systems` below).
  #
  # nixos-unstable is the same channel the author's own NixOS config tracks, so
  # `nix develop` here and `nixos-rebuild` there resolve the same store paths and
  # share one cache.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    # `...` rather than a closed { self, nixpkgs }: adding a second input later
    # would otherwise fail with "called with unexpected argument '<name>'".
    #
    # `self` is load-bearing here, not decoration. It is the store snapshot of
    # this repo's own source, and it is the only thing a command can anchor
    # itself to when it was invoked as `nix run /path/to/repo#lint` from an
    # unrelated directory -- see rootPreamble.
    { self, nixpkgs, ... }:
    let
      lib = nixpkgs.lib;

      # x86_64-darwin is deliberately absent. nixpkgs 26.11 replaced that whole
      # attribute set with `throw "Nixpkgs 26.11 has dropped support for
      # x86_64-darwin"`. genAttrs is lazy, so plain `nix develop` on Linux would
      # not notice -- it detonates later, on `nix flake check --all-systems`.
      # Add it back only against a separate nixpkgs-26.05-darwin input.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      # Stand-in for flake-utils.lib.eachDefaultSystem. Passes `pkgs` rather than
      # a system string, because that is what every call site below wants.
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # ======================================================================
      # PER-REPO BLOCK 1 -- the toolchain
      # ======================================================================
      # Everything the commands below need. `nix flake check` realises this
      # closure, so a typo'd attr name fails at the flake gate instead of
      # surfacing as "command not found" halfway through a task.
      #
      # Explicit `pkgs.foo`, never `with pkgs; [ ... ]`: when an attr disappears
      # in a nixpkgs bump, `with` reports a bare undefined identifier with no
      # hint of which set it came from, and the name is not greppable.
      #
      # Pin language runtimes by MAJOR (python313, not python3): the default
      # alias is already 3.14 territory, and an alias that moves under you
      # invalidates every environment in the fleet on the same afternoon.
      toolchain = pkgs: [
        # ---- this repo's ecosystem ----
        # This repo ships NO manifest -- no requirements.txt, no pyproject.toml,
        # no CI workflow, no Dockerfile. The dependency set below was derived by
        # reading every import in the four .py files: quart (main.py's web
        # framework), httpx (the async API client in main.py and
        # tracker_track.py) and requests (the Discord webhook POST in
        # tracker_track.py). Everything else imported is stdlib -- json,
        # logging, asyncio, time, os, ipaddress.
        #
        # All three exist in nixpkgs, so they go in the interpreter itself
        # rather than behind a `dev-setup` that would have to hardcode the same
        # list a second time. Consequence, and the reason this is worth the
        # deviation from the fleet's venv pattern: this shell needs no network
        # and no bootstrap step, so `nix develop -c python main.py` works cold.
        # If you add an import to the source, add it HERE -- do not reintroduce
        # a requirements.txt that the flake then silently disagrees with.
        (pkgs.python313.withPackages (ps: [
          ps.quart
          ps.httpx
          ps.requests
        ]))
        pkgs.ruff

        # uv earns its place despite there being no `setup` verb: with no
        # manifest, the likely next move for an agent is trying a dependency out
        # before committing to it, and the UV_* vars below keep such a venv on
        # this same interpreter instead of a downloaded second CPython.
        pkgs.uv

        # ---- present in every repo in the fleet ----
        pkgs.git
        pkgs.jq
        pkgs.gnumake
      ];

      # ======================================================================
      # PER-REPO BLOCK 2 -- libraries that get dlopened, not linked
      # ======================================================================
      # The three dependencies above are pure Python and nixpkgs already linked
      # them correctly, so nothing here is needed for the repo as it stands.
      # It is kept minimal-but-present for the uv escape hatch: the moment
      # someone installs a manylinux wheel, its .so files are dlopened, so
      # neither patchelf nor the nix linker ever sees them and NixOS has no
      # /usr/lib for them to find. stdenv.cc.cc.lib supplies libstdc++, which is
      # the one that breaks `import numpy`.
      #
      # This fixes shared libraries only. A prebuilt *executable* out of a wheel
      # still needs a real ELF interpreter at the FHS path
      # `/lib64/ld-linux-x86-64.so.2`. That is a host setting -- stock NixOS
      # ships a stub there that exits 127 with "NixOS cannot run dynamically
      # linked executables" unless `environment.ldso` or `programs.nix-ld.enable`
      # is set -- and no project flake can supply it.
      nativeLibs = pkgs: [
        pkgs.stdenv.cc.cc.lib
        pkgs.zlib
      ];

      # ======================================================================
      # PER-REPO BLOCK 3 -- constant environment variables
      # ======================================================================
      # Only values that are constants belong here. Anything that must READ an
      # existing value (LD_LIBRARY_PATH), UNSET something (SOURCE_DATE_EPOCH) or
      # touch the work tree goes in the shellHook further down.
      #
      # This attrset is applied to BOTH surfaces -- the dev shell and every
      # `nix run` wrapper -- so a command cannot behave differently depending on
      # how it was invoked.
      envVars = pkgs: {
        # Keep uv on the nix interpreter. Left alone it downloads its own
        # portable CPython, which then resolves a different set of wheels than
        # this shell pins: two Pythons, one venv, no way to tell which is live.
        UV_PYTHON = "${pkgs.python313}/bin/python";
        UV_PYTHON_DOWNLOADS = "never";
        # /nix/store and the work tree are usually different filesystems, so
        # uv's default hardlink strategy warns on every single install.
        UV_LINK_MODE = "copy";
        PIP_DISABLE_PIP_VERSION_CHECK = "1";
      };

      # ======================================================================
      # PER-REPO BLOCK 4 -- the command map
      # ======================================================================
      # THE single source of truth. It generates `apps` (so `nix run .#run`
      # works), the `dev-*` wrappers on PATH inside the shell, and `dev-help`.
      # Nothing is written twice, so `nix flake show` can never disagree with
      # what `dev-run` actually runs.
      #
      # Fixed house vocabulary; a verb means the same thing in all 41 repos and
      # a verb the repo has no meaning for is OMITTED, because absence is
      # information and a stub that echoes "not applicable" turns the command
      # map into a liar. Three of the six are absent here, all for real reasons:
      #
      #   setup  nothing to bootstrap -- the interpreter above already carries
      #          every dependency, and the ONE thing this repo does need
      #          (config.json) holds secrets a flake must not invent
      #   build  there is no artifact; the two entrypoints are run from source
      #   test   there is no test suite, and no CI workflow that pretends there
      #          is. Add `test` here the day a tests/ directory exists.
      #
      # `text` is bash under `set -euo pipefail`, shellcheck'd at BUILD time. It
      # starts in the caller's current directory but must never ACT on it.
      # Rules for writing one:
      #   * a bare trailing "$@" is a bug, not the convention. With no arguments
      #     it expands to nothing, and the tool then defaults to `.` -- the
      #     caller's cwd, not this repo. Anchor the no-argument case to
      #     $REPO_ROOT (`"''${@:-$REPO_ROOT}"`) or cd there first, and keep
      #     forwarding explicit arguments untouched. Never unquoted $@ -- that
      #     fails the build (SC2068).
      #   * $REPO_ROOT is this repo, resolved by rootPreamble; use it for
      #     anything stateful, never a bare relative path
      #   * anything that WRITES calls need_writable_checkout first, because
      #     $REPO_ROOT can legitimately be the read-only store snapshot
      #   * pass the batch/non-interactive flag to anything that could prompt:
      #     there is no tty, so a prompt hangs until the agent's timeout
      #   * say "(network)" in the description of anything that needs it
      commands = pkgs: {
        lint = {
          description = "ruff check (this repo; args override)";
          # `ruff check "$@"` -- the first cut of this line -- was a gate that
          # lied. With no arguments ruff falls back to `.`, so `nix run
          # /path/to/repo#lint` from anywhere else printed "All checks passed!"
          # and exited 0 having read none of this repo, while the same verb run
          # from inside it exited 1 on 31 findings. The flake-URL form is what
          # CI and a cold agent use, so that was the form that was green.
          #
          # Read-only, so no need_writable_checkout: when there is no checkout
          # in reach, $REPO_ROOT is the store snapshot of this same source and
          # linting it yields the same verdict.
          text = ''ruff check "''${@:-$REPO_ROOT}"'';
        };
        fmt = {
          description = "ruff format (rewrites files; this repo, args override)";
          # The mutating half of the same defect, and the worse one: a bare "$@"
          # here meant `nix run /path/to/repo#fmt` REWROTE whatever .py files
          # sat in the caller's directory, in some unrelated project, with this
          # repo's formatter. `set --` rather than an inline "''${@:-...}" so the
          # guard can run in the no-argument branch only: an explicit path is
          # the caller's own instruction and is forwarded untouched.
          text = ''
            if [ "$#" -eq 0 ]; then
              need_writable_checkout
              set -- "$REPO_ROOT"
            fi
            ruff format "$@"
          '';
        };
        run = {
          description = "(network) serve the Quart app on config.json's app_port";
          # `cd "$REPO_ROOT"` is how this verb anchors itself, and here the cd
          # is not merely tidier than a path argument, it is the only option:
          # main.py hardcodes cwd-relative paths it cannot be told about --
          # read_json_file('config.json'), write_to_json_file(...,
          # 'tracked_ids.json') and Logger(file_URI='logs/log.txt'). Without the
          # cd, invoking this from a subdirectory silently forks a second set of
          # tracked IDs and log files, and invoking it from another project
          # scatters them there.
          #
          # need_writable_checkout runs unconditionally, unlike in `fmt`: those
          # three paths are written no matter what arguments are passed, so a
          # $REPO_ROOT pointing at the read-only store snapshot cannot work. It
          # fires before the config.json check because "no checkout in reach" is
          # the more fundamental of the two complaints.
          #
          # A bare `python`, not "$REPO_ROOT/.venv/bin/python" -- this repo has
          # no venv, and the wrappers prepend the toolchain above to PATH, so the
          # bare name is exactly the interpreter that carries quart. Do not
          # "fix" this to a venv path.
          #
          # The config.json guard is here because it is gitignored, absent from a
          # fresh clone, and read_json_file returns None on a missing file rather
          # than raising -- so without the guard the failure is a bare
          # `TypeError: 'NoneType' object is not subscriptable` from
          # config['test_flag'], which says nothing about what to do next.
          # "(network)" in the description because serving is the point: the app
          # calls out to config.json's api_endpoint on every submitted ID.
          text = ''
            need_writable_checkout
            cd "$REPO_ROOT"
            if [ ! -f config.json ]; then
              echo "config.json not found in $REPO_ROOT (it is gitignored)." >&2
              echo "Create it with keys: app_port, api_endpoint, test_flag -- plus" >&2
              echo "dc_webhook_url for tracker_track.py, the polling daemon that is" >&2
              echo "this repo's second entrypoint (\`python tracker_track.py\`)." >&2
              exit 1
            fi
            python main.py "$@"
          '';
        };
      };

      # ======================================================================
      # GENERIC MACHINERY -- byte-identical in all 41 repos, do not edit
      # ======================================================================

      # Prepend, never assign: a host LD_LIBRARY_PATH may be carrying something
      # the user needs, and clobbering it breaks binaries they launch from here.
      # Linux only -- on darwin the loader variable is DYLD_*, and exporting a
      # Linux-shaped value there is at best useless.
      ldPreamble =
        pkgs:
        lib.optionalString (pkgs.stdenv.hostPlatform.isLinux && nativeLibs pkgs != [ ]) ''
          export LD_LIBRARY_PATH="${lib.makeLibraryPath (nativeLibs pkgs)}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        '';

      # Every command gets $SRC_ROOT and $REPO_ROOT. `nix run` and `nix develop`
      # both start in whatever directory they were invoked from, and no verb may
      # act on that directory -- these two are what it acts on instead.
      #
      # $SRC_ROOT is this flake's own source, snapshotted into the store when
      # the flake was evaluated. It is the one anchor that is always available:
      # `nix run /path/to/repo#lint` tells the running program nothing whatever
      # about /path/to/repo (flake refs are location-independent by design, and
      # there is no $FLAKE_DIR to read), so without `self` a wrapper invoked
      # that way has literally no way to name the repo it belongs to. Its one
      # limitation is that it is read-only, being a store path.
      #
      # $REPO_ROOT is the writable checkout when the caller is standing in one,
      # and $SRC_ROOT when they are not. `git rev-parse --show-toplevel` alone
      # is NOT enough to find that checkout: run from inside some OTHER git
      # repo it cheerfully answers with THAT repo's top level, and a verb that
      # trusts the answer formats a stranger's source tree. So a candidate has
      # to prove it is a checkout of this flake, by carrying a byte-identical
      # flake.nix. Compared with bash's own $(<file) rather than cmp or
      # sha256sum, so the check depends on no package at all.
      #
      # Consequence worth knowing: edit flake.nix and the dev-* wrappers in an
      # already-open `nix develop` stop recognising the tree, because they were
      # built from the previous flake.nix. That is a stale shell telling you so
      # -- re-enter it. `nix run` re-evaluates every time and never sees this.
      rootPreamble = ''
        SRC_ROOT=${lib.escapeShellArg self}
        export SRC_ROOT
        REPO_ROOT="$SRC_ROOT"
        _toplevel="$(git rev-parse --show-toplevel 2>/dev/null || true)"
        if [ -n "$_toplevel" ] && [ -f "$_toplevel/flake.nix" ] &&
          [ "$(<"$_toplevel/flake.nix")" = "$(<"$SRC_ROOT/flake.nix")" ]; then
          REPO_ROOT="$_toplevel"
        fi
        unset _toplevel
        export REPO_ROOT
      '';

      # Wrappers only, not the shellHook -- an interactive shell has no business
      # carrying this function around. Any command text that writes files calls
      # it first, and it is the reason a mutating verb can fail loudly instead of
      # falling back to "well, the cwd then".
      guardPreamble = ''
        need_writable_checkout() {
          if [ "$REPO_ROOT" != "$SRC_ROOT" ]; then
            return 0
          fi
          echo "This command rewrites files, so it needs a writable checkout of" >&2
          echo "this repo -- and standing in $PWD there is none: no parent" >&2
          echo "directory is a checkout of this flake. The only tree in reach is" >&2
          echo "the read-only store snapshot $SRC_ROOT, and rewriting $PWD" >&2
          echo "instead is exactly the bug this guard exists to prevent." >&2
          echo "cd into the repo (or \`nix develop\` it), or pass an explicit path." >&2
          exit 1
        }
      '';

      # One derivation per command, reused by both `apps` and the dev shell, so
      # the two can never diverge. `dev-` prefixed because a bare `test` binary
      # earlier on PATH would shadow the POSIX shell builtin and quietly break
      # every script in the repo that uses it.
      wrappers =
        pkgs:
        lib.mapAttrs (
          name: cmd:
          pkgs.writeShellApplication {
            name = "dev-${name}";
            runtimeInputs = toolchain pkgs;
            runtimeEnv = envVars pkgs;
            meta.description = cmd.description;
            text = ''
              ${rootPreamble}
              ${guardPreamble}
              ${ldPreamble pkgs}
              ${cmd.text}
            '';
          }
        ) (commands pkgs);

      helpFor =
        pkgs:
        let
          cmds = commands pkgs;
          names = lib.attrNames cmds;
          width = lib.foldl' (a: n: lib.max a (builtins.stringLength n)) 0 names;
          pad = n: n + lib.concatStrings (lib.genList (_: " ") (width - builtins.stringLength n));
          line = n: c: "  dev-${pad n}  ${c.description}";
        in
        pkgs.writeShellApplication {
          name = "dev-help";
          meta.description = "print this repo's command map (works offline)";
          text = ''
            cat <<'EOF'
            ${lib.concatStringsSep "\n" (lib.mapAttrsToList line cmds)}
            EOF
          '';
        };
    in
    {
      # `nix flake show` -- the discovery entrypoint, and deliberately the whole
      # machine-facing contract: every app carries a meta.description, which
      # `nix flake show` prints inline and `nix flake show --json` exposes at
      # .apps.<system>.<name>.description. Pure evaluation, so an agent gets the
      # entire command map in one cheap call without reading a README.
      #
      # Do NOT invent a top-level output for this (`agentManifest`, `probeThing`
      # ...). Nix answers with `warning: unknown flake output '<name>'` on every
      # single `nix flake check`, forever.
      apps = forAllSystems (
        pkgs:
        lib.mapAttrs (name: cmd: {
          type = "app";
          program = "${(wrappers pkgs).${name}}/bin/dev-${name}";
          meta.description = cmd.description;
        }) (commands pkgs)
      );

      # `nix develop` -- the toolchain, plus a dev-<verb> for every app.
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = toolchain pkgs ++ lib.attrValues (wrappers pkgs) ++ [ (helpFor pkgs) ];

          env = envVars pkgs;

          # Some C extensions and node-gyp addons compile at -O0, where glibc's
          # _FORTIFY_SOURCE becomes a hard error instead of a warning.
          hardeningDisable = [ "fortify" ];

          shellHook = ''
            # mkShell inherits SOURCE_DATE_EPOCH=315532800 (1980-01-01) from
            # stdenv, and any wheel or zip built in here then dies with "ZIP does
            # not support timestamps before 1980".
            unset SOURCE_DATE_EPOCH

            ${rootPreamble}
            ${ldPreamble pkgs}

            # Nothing networked, nothing stateful and nothing interactive above
            # this line, and nothing below it either. No venv creation, no
            # `npm install`, no `dotnet restore`, no `read`, no `exec $SHELL`.
            # Bootstrapping in the hook makes a cold `nix develop -c pytest`
            # start downloading before it runs anything, on EVERY invocation --
            # the exact failure an unattended agent cannot diagnose. That is what
            # `dev-setup` is for.

            # The banner is interactive-only, and this guard is load-bearing:
            # shellHook output lands on the STDOUT of `nix develop -c <cmd>`, so
            # an unguarded echo corrupts anything parsing it
            # (`nix develop -c cat x.json | jq` fails to parse). $- is the only
            # reliable discriminator here -- it lacks `i` for `nix develop -c`
            # and has it at an interactive prompt. Do not test $PS1 (unset in
            # both) or $IN_NIX_SHELL (set in both). >&2 is the second layer, for
            # the case where a caller runs us on a pty.
            case $- in
              *i*) echo "spy-shield dev shell -- 'dev-help' for the command map" >&2 ;;
            esac
          '';
        };
      });

      # `nix flake check` -- honest by construction. It realises the toolchain
      # closure (so a typo'd or currently-broken attr fails here) and builds
      # every wrapper, which runs shellcheck over every command text. Add real
      # test derivations beside it. NEVER add a check that always passes: an
      # agent reads "all checks passed!" as a signal, and a fake check makes
      # `nix flake check` a liar.
      checks = forAllSystems (pkgs: {
        toolchain =
          pkgs.runCommand "toolchain-check"
            {
              nativeBuildInputs = toolchain pkgs ++ lib.attrValues (wrappers pkgs);
            }
            ''
              for verb in ${lib.escapeShellArgs (lib.attrNames (commands pkgs))}; do
                command -v "dev-$verb" > /dev/null || {
                  echo "dev-$verb is not on PATH" >&2
                  exit 1
                }
              done
              touch "$out"
            '';
      });

      # `nix fmt` -- formats the *Nix* in this repo; project code is `dev-fmt`.
      # nixfmt-tree (the treefmt wrapper) rather than bare nixfmt, because bare
      # nixfmt tries to parse every path handed to it and fails on non-Nix files.
      # This file ships already formatted, so `nix fmt` is a no-op rather than a
      # diff in 41 repos.
      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
