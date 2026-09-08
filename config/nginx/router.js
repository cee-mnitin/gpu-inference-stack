// vLLM Router JavaScript module for nginx njs
// Parses request body and routes based on model field

// Model mapping: model name -> upstream location name
const MODEL_MAP = {
    'qwen3.6': '@qwen3_6',
    // Add more models here as needed
    // 'model-name': '@upstream_name',
};

function route(r) {
    try {
        // Parse request body as JSON
        const body = r.requestText || r.requestBody;
        if (!body) {
            r.return(400, JSON.stringify({
                error: {
                    message: 'Request body is required',
                    type: 'invalid_request_error'
                }
            }));
            return;
        }

        const req = JSON.parse(body);
        const model = req.model;

        if (!model) {
            r.return(400, JSON.stringify({
                error: {
                    message: 'Model field is required in request',
                    type: 'invalid_request_error'
                }
            }));
            return;
        }

        // Look up upstream for this model
        const upstream = MODEL_MAP[model];

        if (!upstream) {
            const available = Object.keys(MODEL_MAP).join(', ');
            r.return(404, JSON.stringify({
                error: {
                    message: 'Model ' + model + ' not found. Available: ' + available,
                    type: 'invalid_request_error'
                }
            }));
            return;
        }

        // Internal redirect to the named location
        r.internalRedirect(upstream);

    } catch (e) {
        r.return(500, JSON.stringify({
            error: {
                message: 'Internal routing error: ' + e.message,
                type: 'internal_error'
            }
        }));
    }
}

export default { route };
