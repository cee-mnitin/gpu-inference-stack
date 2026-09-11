// Model-aware router for the vLLM instances this box runs.
//
// NOTHING HERE IS HARDCODED TO A MODEL NAME. The map is injected by nginx from
// environment variables at request time, so one committed file serves every
// box in the fleet. It previously read:
//
//     const MODEL_MAP = { 'qwen3.6': '@qwen3_6' };
//
// which was true only on crimson-llm2. On any other box the router advertised
// a model it did not have and rejected requests for the one it did — while
// starting cleanly and reporting healthy, so nothing surfaced the mismatch.
//
// The env vars come from the compose service and mirror the vllm instances:
//   ROUTER_MODEL_1 / ROUTER_UPSTREAM_1   (always present)
//   ROUTER_MODEL_2 / ROUTER_UPSTREAM_2   (empty unless vllm2 is enabled)
//   ROUTER_MODEL_3 / ROUTER_UPSTREAM_3   (empty unless vllm3 is enabled)

function modelMap(r) {
    var map = {};
    for (var i = 1; i <= 3; i++) {
        var name = process.env['ROUTER_MODEL_' + i];
        var up = process.env['ROUTER_UPSTREAM_' + i];
        if (name && up) {
            map[name] = up;
        }
    }
    return map;
}

// GET /v1/models — built from the same map that does the routing, so the list
// can never disagree with what is actually routable. The old version returned
// a static literal, which is how a box could advertise a model it did not run.
function models(r) {
    var map = modelMap(r);
    var data = [];
    for (var name in map) {
        data.push({
            id: name,
            object: 'model',
            owned_by: 'vllm-infra',
        });
    }
    r.headersOut['Content-Type'] = 'application/json';
    r.return(200, JSON.stringify({ object: 'list', data: data }));
}

function route(r) {
    try {
        var body = r.requestText || r.requestBody;
        if (!body) {
            r.return(400, JSON.stringify({
                error: {
                    message: 'Request body is required',
                    type: 'invalid_request_error',
                },
            }));
            return;
        }

        var req = JSON.parse(body);
        var model = req.model;
        if (!model) {
            r.return(400, JSON.stringify({
                error: {
                    message: 'Model field is required in request',
                    type: 'invalid_request_error',
                },
            }));
            return;
        }

        var map = modelMap(r);
        var target = map[model];

        // Single-instance boxes are the common case, and there a request for
        // the "wrong" name has exactly one plausible destination. Forwarding
        // is friendlier than a 404 and matches how the old `location /`
        // catch-all behaved — but say so in a header, so a consumer chasing a
        // name mismatch can see what happened instead of guessing.
        if (!target) {
            var names = Object.keys(map);
            if (names.length === 1) {
                r.headersOut['X-Router-Fallback'] = 'requested=' + model +
                    '; served-by=' + names[0];
                r.internalRedirect(map[names[0]]);
                return;
            }
            r.return(404, JSON.stringify({
                error: {
                    message: 'Model "' + model + '" is not served here. ' +
                             'Available: ' + names.join(', '),
                    type: 'invalid_request_error',
                    code: 'model_not_found',
                },
            }));
            return;
        }

        r.internalRedirect(target);
    } catch (e) {
        r.return(400, JSON.stringify({
            error: {
                message: 'Invalid JSON in request body: ' + e.message,
                type: 'invalid_request_error',
            },
        }));
    }
}

export default { route, models };
