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

  invalidStateCase = actorsSystem.run {
    actors = {
      bad = invalidStateActor;
    };
  };
in
{
  normal = base;
  errs = errorCase.final;
  strictErrs = strictCase.final;
  badActorMsgErrs = badActorMsgCase.final;
  invalidState = invalidStateCase.final;
  tests = {
    unknown-msg-type = hasKind "unknown-msg-type" errorCase.final.errors;
    spawn-collision = hasKind "spawn-collision" errorCase.final.errors;
    strict-halts = strictCase.final.halted or false;
    strict-first-error-unknown-msg = (strictCase.final.haltError.kind or "") == "unknown-msg-type";
    bad-actor-message = hasKind "bad-actor-message" badActorMsgCase.final.errors;
    invalid-state-event = hasKind "invalid-state" invalidStateCase.final.events;
  };
}
