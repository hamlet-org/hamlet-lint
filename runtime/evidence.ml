type ('input, 'output, 'handled) slot = {
  dispatch :
    'result.
    'input ->
    handled:('handled -> 'result) ->
    forward:('output -> 'result) ->
    'result;
}
