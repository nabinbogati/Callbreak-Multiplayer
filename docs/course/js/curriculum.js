/* Build Call Break — curriculum container. Modules are defined in modules-*.js.
   Each pushes a module object onto window.COURSE_MODULES. */
var COURSE_MODULES = [];
var COURSE_STEPS = []; // flattened: { moduleIndex, stepIndex, module, step }
var COURSE_MODULE_OF = {};

function REGISTER(module) {
  var mi = COURSE_MODULES.length;
  COURSE_MODULES.push(module);
  for (var si = 0; si < module.steps.length; si++) {
    var s = module.steps[si];
    s.moduleIndex = mi;
    s.stepIndex = si;
    COURSE_STEPS.push({ module: module, step: s });
    COURSE_MODULE_OF[s.id] = { module: module, index: COURSE_STEPS.length - 1, moduleIndex: mi, stepIndex: si };
  }
}
