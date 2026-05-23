{
  ned,
  bend,
}:
let
  warn = builtins.warn or (msg: v: builtins.trace "[1;35mevaluation warning:[0m ${msg}" v);

  messageLens = bend.recordAll {
    to = bend.str;
    from = bend.str;
    type = bend.str;
    payload = bend.identity;
  };

  cmdSendLens = bend.recordAll {
    op = bend.str;
    to = bend.str;
    type = bend.str;
    payload = bend.identity;
  };

  cmdSpawnLens = bend.recordAll {
    op = bend.str;
    name = bend.str;
    actor = bend.identity;
  };

  msg = {
    mkLens =
      payloadLens:
      bend.recordAll {
        to = bend.str;
        from = bend.str;
        type = bend.str;
        payload = payloadLens;
      };
  };

  mkActor =
    {
      state ? { },
      lenses ? { },
      on ? { },
      stateLens ? bend.identity,
    }:
    let
      defaultStep =
        actorId: actor: m:
        if builtins.match "^\\$sys\\..*" m.type != null then
          {
            state = actor.state or { };
            commands = [ ];
            events = [ ];
          }
        else
          {
            state = actor.state or { };
            commands = [ ];
            events = [
              {
                kind = "unhandled";
                actor = actorId;
                type = m.type;
              }
            ];
          };

      step =
        actorId: actor: m:
        let
          handler = on.${m.type} or null;
          out = if handler == null then defaultStep actorId actor m else handler actorId actor m;
          candidateState = out.state or (actor.state or { });
          checked = stateLens.get candidateState;
        in
        if checked ? left then
          builtins.deepSeq (warn "[actors-system] invalid-state actor=${actorId}" null) {
            state = actor.state or { };
            commands = [ ];
            events = (out.events or [ ]) ++ [
              {
                kind = "invalid-state";
                actor = actorId;
                got = candidateState;
                parse = checked.left;
              }
            ];
          }
        else
          {
            state = checked.right;
            commands = out.commands or [ ];
            events = out.events or [ ];
          };
    in
    {
      inherit step state stateLens;
      messageParsers = lenses;
    };

  cmd = {
    send =
      {
        to,
        type,
        payload,
      }:
      {
        op = "send";
        inherit to type payload;
      };
    spawn =
      { name, actor }:
      {
        op = "spawn";
        inherit name actor;
      };
  };

  stripFns =
    state:
    state
    // {
      actors = builtins.mapAttrs (
        _: actor:
        builtins.removeAttrs actor [
          "step"
          "messageParsers"
          "stateLens"
        ]
      ) state.actors;
    };

  errSummary =
    err:
    let
      parts = builtins.filter (x: x != "") [
        (if err ? actor then "actor=${err.actor}" else "")
        (if err ? by then "by=${err.by}" else "")
        (if err ? op then "op=${err.op}" else "")
        (if err ? type then "type=${err.type}" else "")
        (if err ? id then "id=${err.id}" else "")
        (if err ? to then "to=${err.to}" else "")
      ];
    in
    if parts == [ ] then err.kind else "${err.kind} " + builtins.concatStringsSep " " parts;

  run =
    {
      actors,
      queue ? [ ],
      events ? [ ],
      mode ? "lenient",
      includeStates ? false,
    }:
    let
      onError =
        state: err:
        let
          warned = warn "[actors-system] ${errSummary err}" null;
        in
        builtins.deepSeq warned (
          if mode == "strict" then
            state
            // {
              halted = true;
              haltError = err;
              queue = [ ];
              errors = (state.errors or [ ]) ++ [ err ];
            }
          else
            state
            // {
              errors = (state.errors or [ ]) ++ [ err ];
            }
        );

      applySend =
        senderId: state: command:
        let
          parsed = cmdSendLens.get command;
        in
        if parsed ? left then
          onError state {
            kind = "bad-command";
            op = "send";
            input = command;
            by = senderId;
            parse = parsed.left;
          }
        else
          state
          // {
            queue = state.queue ++ [ ({ from = senderId; } // builtins.removeAttrs parsed.right [ "op" ]) ];
          };

      applySpawn =
        senderId: state: command:
        let
          parsed = cmdSpawnLens.get command;
        in
        if parsed ? left then
          onError state {
            kind = "bad-command";
            op = "spawn";
            input = command;
            by = senderId;
            parse = parsed.left;
          }
        else
          let
            id = parsed.right.name;
          in
          if state.actors ? ${"${id}"} then
            onError state {
              kind = "spawn-collision";
              by = senderId;
              inherit id;
            }
          else
            state
            // {
              actors = state.actors // {
                ${"${id}"} = parsed.right.actor;
              };
              queue = state.queue ++ [
                {
                  to = senderId;
                  from = "system";
                  type = "$sys.spawned";
                  payload = {
                    name = parsed.right.name;
                    inherit id;
                  };
                }
              ];
              events = state.events ++ [
                {
                  kind = "spawned";
                  by = senderId;
                  name = parsed.right.name;
                  inherit id;
                }
              ];
            };

      applyCommand =
        senderId: state: command:
        let
          op = command.op or "";
        in
        if op == "send" then
          applySend senderId state command
        else if op == "spawn" then
          applySpawn senderId state command
        else
          onError state {
            kind = "unknown-command";
            command = command;
            by = senderId;
          };

      handleOne =
        state:
        let
          rawMsg = builtins.head state.queue;
          rest = builtins.tail state.queue;
          parsed = messageLens.get rawMsg;
        in
        if parsed ? left then
          onError (state // { queue = rest; }) {
            kind = "bad-message";
            input = rawMsg;
            parse = parsed.left;
          }
        else
          let
            m = parsed.right;
            actor = state.actors.${m.to} or null;
          in
          if actor == null then
            onError (state // { queue = rest; }) {
              kind = "dead-letter";
              to = m.to;
              type = m.type;
            }
          else
            let
              isSysMsg = builtins.match "^\\$sys\\..*" m.type != null;
              parsedForActor =
                if isSysMsg then
                  { right = m; }
                else
                  let
                    p = actor.messageParsers.${m.type} or null;
                  in
                  if p == null then null else p.get m;
            in
            if !isSysMsg && parsedForActor == null then
              builtins.deepSeq (warn "[actors-system] unknown-msg-type actor=${m.to} type=${m.type}" null) (
                onError (state // { queue = rest; }) {
                  kind = "unknown-msg-type";
                  actor = m.to;
                  type = m.type;
                }
              )
            else if parsedForActor ? left then
              onError (state // { queue = rest; }) {
                kind = "bad-actor-message";
                actor = m.to;
                type = m.type;
                input = m;
                parse = parsedForActor.left;
              }
            else
              let
                out = actor.step m.to actor parsedForActor.right;
                base = state // {
                  queue = rest;
                  actors = state.actors // {
                    ${"${m.to}"} = actor // {
                      state = out.state;
                    };
                  };
                  events = state.events ++ out.events;
                };
              in
              builtins.foldl' (s: c: applyCommand m.to s c) base out.commands;

      bootMsgs = map (id: {
        to = id;
        from = "system";
        type = "$sys.boot";
        payload = { };
      }) (builtins.attrNames actors);

      startState = {
        inherit actors events;
        queue = queue ++ bootMsgs;
        errors = [ ];
        halted = false;
      };

      statesWithKeys = builtins.genericClosure {
        startSet = [
          {
            key = 0;
            state = startState;
          }
        ];
        operator =
          item:
          if item.state.queue == [ ] || (item.state.halted or false) then
            [ ]
          else
            [
              {
                key = item.key + 1;
                state = handleOne item.state;
              }
            ];
      };

      allStates = map (x: x.state) statesWithKeys;
      finalRaw = builtins.elemAt allStates ((builtins.length allStates) - 1);
      statesRaw = if includeStates then allStates else [ ];
    in
    {
      states = if includeStates then map stripFns statesRaw else [ ];
      final = stripFns finalRaw;
    };
in
{
  inherit
    run
    mkActor
    cmd
    msg
    ;
}
