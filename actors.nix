{
  ned,
  bend,
  actorsSystem ? import ./actors-system.nix { inherit ned bend; },
}:
let
  workerActor = actorsSystem.mkActor {
    state = {
      replies = 0;
      spawnedBy = "root";
      lastFrom = "";
    };
    lenses = {
      ping = actorsSystem.msg.mkLens (
        bend.recordAll {
          text = bend.str;
        }
      );
    };
    stateLens = bend.recordAll {
      replies = bend.int;
      spawnedBy = bend.str;
      lastFrom = bend.str;
    };
    on = {
      ping = actorId: actor: msg: {
        state = (actor.state or { }) // {
          replies = (actor.state.replies or 0) + 1;
          lastFrom = msg.from;
        };
        commands = [
          (actorsSystem.cmd.send {
            to = msg.from;
            type = "pong";
            payload = {
              via = actorId;
              worker = true;
            };
          })
        ];
        events = [
          {
            kind = "worker-replied";
            actor = actorId;
            to = msg.from;
          }
        ];
      };
    };
  };

  echoActor = actorsSystem.mkActor {
    state = {
      replies = 0;
      lastFrom = "";
    };
    lenses = {
      ping = actorsSystem.msg.mkLens (
        bend.recordAll {
          text = bend.str;
        }
      );
    };
    stateLens = bend.recordAll {
      replies = bend.int;
      lastFrom = bend.str;
    };
    on = {
      ping = actorId: actor: msg: {
        state = (actor.state or { }) // {
          replies = (actor.state.replies or 0) + 1;
          lastFrom = msg.from;
        };
        commands = [
          (actorsSystem.cmd.send {
            to = msg.from;
            type = "pong";
            payload = {
              via = actorId;
              text = msg.payload.text or "";
            };
          })
        ];
        events = [
          {
            kind = "echo-replied";
            actor = actorId;
            to = msg.from;
          }
        ];
      };
    };
  };

  sinkActor = actorsSystem.mkActor {
    state = {
      seen = 0;
    };
    lenses = {
      pong = actorsSystem.msg.mkLens (
        bend.recordAll {
          via = bend.str;
          text = bend.str;
        }
      );
    };
    stateLens = bend.recordAll {
      seen = bend.int;
    };
    on = {
      pong = _actorId: actor: _msg: {
        state = (actor.state or { }) // {
          seen = (actor.state.seen or 0) + 1;
        };
        commands = [ ];
        events = [ ];
      };
    };
  };

  rootActor = actorsSystem.mkActor {
    state = {
      pongs = 0;
      booted = false;
      boots = 0;
      spawned = { };
      lastPong = {
        via = "";
        text = "";
      };
    };
    lenses = {
      pong = actorsSystem.msg.mkLens (
        bend.recordAll {
          via = bend.str;
          text = bend.str;
        }
      );
    };
    stateLens = bend.recordAll {
      pongs = bend.int;
      booted = bend.bool;
      boots = bend.int;
      spawned = bend.identity;
      lastPong = bend.recordAll {
        via = bend.str;
        text = bend.str;
      };
    };
    on = {
      "$sys.boot" = actorId: actor: _msg: {
        state = (actor.state or { }) // {
          booted = true;
          boots = (actor.state.boots or 0) + 1;
        };
        commands = [
          (actorsSystem.cmd.spawn {
            name = "worker-1";
            actor = workerActor;
          })
          (actorsSystem.cmd.send {
            to = "echo";
            type = "ping";
            payload = {
              text = "hello";
            };
          })
        ];
        events = [
          {
            kind = "root-boot";
            actor = actorId;
          }
        ];
      };

      "$sys.spawned" = actorId: actor: msg: {
        state = (actor.state or { }) // {
          spawned = (actor.state.spawned or { }) // {
            ${"${msg.payload.name}"} = msg.payload.id;
          };
        };
        commands = [ ];
        events = [
          {
            kind = "spawn-ack";
            actor = actorId;
            name = msg.payload.name;
            id = msg.payload.id;
          }
        ];
      };

      pong = actorId: actor: msg: {
        state = (actor.state or { }) // {
          pongs = (actor.state.pongs or 0) + 1;
          lastPong = msg.payload;
        };
        commands = [ ];
        events = [
          {
            kind = "got-pong";
            actor = actorId;
            from = msg.from;
            payload = msg.payload;
          }
        ];
      };
    };
  };
in
let
  base = actorsSystem.run {
    actors = {
      root = rootActor;
      echo = echoActor;
    };
  };
  errorCase = actorsSystem.run {
    actors = {
      root = rootActor;
      echo = echoActor;
    };
    queue = [
      {
        to = "root";
        from = "tester";
        type = "ping";
        payload = {
          text = "bad";
        };
      }
      {
        to = "root";
        from = "tester";
        type = "$sys.boot";
        payload = { };
      }
    ];
  };
  hasKind = kind: xs: builtins.any (x: (x.kind or null) == kind) xs;

  strictCase = actorsSystem.run {
    actors = {
      root = rootActor;
      echo = echoActor;
    };
    mode = "strict";
    queue = [
      {
        to = "root";
        from = "tester";
        type = "ping";
        payload = {
          text = "bad";
        };
      }
      {
        to = "root";
        from = "tester";
        type = "$sys.boot";
        payload = { };
      }
    ];
  };

  badActorMsgCase = actorsSystem.run {
    actors = {
      root = rootActor;
      echo = echoActor;
    };
    queue = [
      {
        to = "root";
        from = "tester";
        type = "pong";
        payload = {
          via = 1;
          text = 2;
        };
      }
    ];
  };

  stackSafeCase = actorsSystem.run {
    actors = {
      echo = echoActor;
      sink = sinkActor;
    };
    queue = builtins.genList (_: {
      to = "echo";
      from = "sink";
      type = "ping";
      payload = {
        text = "stress";
      };
    }) 20480;
  };

  invalidStateActor = actorsSystem.mkActor {
    state = {
      n = 0;
    };
    stateLens = bend.recordAll { n = bend.int; };
    on = {
      "$sys.boot" = _id: _actor: _msg: {
        state = {
          n = "bad";
        };
        commands = [ ];
        events = [ ];
      };
    };
  };

  dynamicLensActor = actorsSystem.mkActor {
    state = {
      phase = "text";
      seen = 0;
      last = null;
    };
    lenses = state: {
      ping = actorsSystem.msg.mkLens (
        if (state.phase or "text") == "text" then
          bend.recordAll { text = bend.str; }
        else
          bend.recordAll { n = bend.int; }
      );
    };
    stateLens = bend.recordAll {
      phase = bend.str;
      seen = bend.int;
      last = bend.identity;
    };
    on = {
      ping =
        _id: actor: msg:
        let
          nextPhase = if (actor.state.phase or "text") == "text" then "num" else "text";
        in
        {
          state = (actor.state or { }) // {
            phase = nextPhase;
            seen = (actor.state.seen or 0) + 1;
            last = msg.payload;
          };
          commands = [ ];
          events = [
            {
              kind = "dynamic-lens-step";
              phase = nextPhase;
            }
          ];
        };
    };
  };

  invalidStateCase = actorsSystem.run {
    actors = {
      bad = invalidStateActor;
    };
  };

  dynamicLensCase = actorsSystem.run {
    actors = {
      dyn = dynamicLensActor;
    };
    queue = [
      {
        to = "dyn";
        from = "tester";
        type = "ping";
        payload = {
          text = "hello";
        };
      }
      {
        to = "dyn";
        from = "tester";
        type = "ping";
        payload = {
          n = 7;
        };
      }
      {
        to = "dyn";
        from = "tester";
        type = "ping";
        payload = {
          n = 9;
        };
      }
    ];
  };

in
{
  normal = base;
  errs = errorCase.final;
  strictErrs = strictCase.final;
  badActorMsgErrs = badActorMsgCase.final;
  invalidState = invalidStateCase.final;
  dynamicLens = dynamicLensCase.final;
  tests = {
    unknown-msg-type = hasKind "unknown-msg-type" errorCase.final.errors;
    spawn-collision = hasKind "spawn-collision" errorCase.final.errors;
    strict-halts = strictCase.final.halted or false;
    strict-first-error-unknown-msg = (strictCase.final.haltError.kind or "") == "unknown-msg-type";
    bad-actor-message = hasKind "bad-actor-message" badActorMsgCase.final.errors;
    invalid-state-event = hasKind "invalid-state" invalidStateCase.final.events;
    dynamic-lens-bad-actor-message = hasKind "bad-actor-message" dynamicLensCase.final.errors;
    dynamic-lens-seen-two = (dynamicLensCase.final.actors.dyn.state.seen or 0) == 2;
    dynamic-lens-last-num = (dynamicLensCase.final.actors.dyn.state.last.n or (-1)) == 7;
    stack-safety-check =
      (builtins.length stackSafeCase.final.errors) == 0
      && (stackSafeCase.final.halted or false) == false
      && (builtins.length stackSafeCase.final.queue) == 0;
  };
}
