/* dc-lite.js — 原型离线运行时（只用于本地打开导出的原型页面） */
(function () {
  'use strict';

  var LIT = /^\s*(-?\d+(?:\.\d+)?|true|false|null)\s*$/;
  var HOLE = /\{\{\s*([^}]*?)\s*\}\}/g;
  var ONE = /^\{\{\s*([^}]*?)\s*\}\}$/;
  var BOOL_ATTRS = { disabled: 1, checked: 1, hidden: 1, selected: 1, readonly: 1, required: 1, multiple: 1 };

  function lookup(expr, scope) {
    var m = LIT.exec(expr);
    if (m) {
      var s = m[1];
      if (s === 'true') return true;
      if (s === 'false') return false;
      if (s === 'null') return null;
      return Number(s);
    }
    var parts = expr.split('.');
    var v;
    for (var i = scope.length - 1; i >= 0; i--) {
      if (scope[i] && Object.prototype.hasOwnProperty.call(scope[i], parts[0])) { v = scope[i][parts[0]]; break; }
    }
    for (var j = 1; j < parts.length; j++) {
      if (v == null) return undefined;
      v = v[parts[j]];
    }
    return v;
  }

  function interp(str, scope) {
    return str.replace(HOLE, function (_, e) {
      var v = lookup(e, scope);
      return v == null ? '' : String(v);
    });
  }

  function raw(str, scope) {
    var m = ONE.exec(str);
    if (m) return lookup(m[1], scope);
    return interp(str, scope);
  }

  function evtName(attr, el) {
    var n = attr.slice(2).toLowerCase();
    if (n === 'change') {
      var t = el.tagName.toLowerCase();
      if (t === 'input' || t === 'textarea') return 'input';
    }
    return n;
  }

  function listen(el, type) {
    el.__l = el.__l || {};
    if (el.__l[type]) return;
    el.__l[type] = true;
    el.addEventListener(type, function (ev) {
      var h = el.__h && el.__h[type];
      if (h) h(ev);
    });
  }

  function kids(node) {
    if (node.tagName && node.tagName.toLowerCase() === 'template' && node.content) return node.content.childNodes;
    return node.childNodes;
  }

  var registry = {};

  function build(node, scope, out) {
    if (node.nodeType === 3) {
      out.push(document.createTextNode(interp(node.data, scope)));
      return;
    }
    if (node.nodeType !== 1) return;
    var tag = node.tagName.toLowerCase();
    if (tag === 'template' || tag === 'TEMPLATE') {
      var kind = node.getAttribute('data-sc');
      if (kind === 'if') {
        if (raw(node.getAttribute('value') || '', scope)) buildAll(kids(node), scope, out);
        return;
      }
      if (kind === 'for') {
        var list = raw(node.getAttribute('list') || '', scope) || [];
        var as = node.getAttribute('as') || 'item';
        for (var i = 0; i < list.length; i++) {
          var o = {}; o[as] = list[i];
          buildAll(kids(node), scope.concat([o]), out);
        }
        return;
      }
      if (kind === 'import') {
        var name = node.getAttribute('name');
        var props = {};
        for (var a = 0; a < node.attributes.length; a++) {
          var at = node.attributes[a];
          if (at.name === 'name' || at.name === 'data-sc' || at.name.indexOf('hint-') === 0) continue;
          props[at.name] = raw(at.value, scope);
        }
        var def = registry[name];
        if (def) {
          var inst = new def.Cls(props);
          var vals = inst.renderVals ? inst.renderVals() : {};
          buildAll(kids(def.tpl), [vals], out);
        }
        return;
      }
      return;
    }
    if (tag === 'helmet') return;
    var el = node.cloneNode(false);
    var attrs = [];
    for (var k = 0; k < node.attributes.length; k++) attrs.push(node.attributes[k]);
    for (var q = 0; q < attrs.length; q++) {
      var an = attrs[q].name, av = attrs[q].value;
      if (an.indexOf('hint-') === 0) { el.removeAttribute(an); continue; }
      if (/^on[a-z]/i.test(an) && av.indexOf('{{') >= 0) {
        el.removeAttribute(an);
        var fn = raw(av, scope);
        var type = evtName(an, el);
        el.__h = el.__h || {};
        if (typeof fn === 'function') { el.__h[type] = fn; listen(el, type); }
        continue;
      }
      if (av.indexOf('{{') < 0) continue;
      var v = raw(av, scope);
      if (an === 'ref') { el.removeAttribute(an); if (typeof v === 'function') el.__ref = v; continue; }
      if (an === 'value' && (tag === 'input' || tag === 'textarea' || tag === 'select')) {
        el.__value = v == null ? '' : String(v);
        el.removeAttribute('value');
        continue;
      }
      if (BOOL_ATTRS[an]) {
        if (v === true || (v && v !== 'false')) el.setAttribute(an, ''); else el.removeAttribute(an);
        continue;
      }
      if (typeof v === 'boolean') { el.setAttribute(an, v ? 'true' : 'false'); continue; }
      el.setAttribute(an, v == null ? '' : String(v));
    }
    var ch = [];
    buildAll(kids(node), scope, ch);
    for (var c = 0; c < ch.length; c++) el.appendChild(ch[c]);
    if (el.__value != null) el.value = el.__value;
    out.push(el);
  }

  function buildAll(nodes, scope, out) {
    for (var i = 0; i < nodes.length; i++) build(nodes[i], scope, out);
  }

  function sameKind(o, n) {
    if (o.nodeType !== n.nodeType) return false;
    if (o.nodeType !== 1) return true;
    return o.tagName === n.tagName && o.namespaceURI === n.namespaceURI;
  }

  function adopt(n, refs) {
    if (n.__ref) refs.push([n.__ref, n]);
    if (n.childNodes) for (var i = 0; i < n.childNodes.length; i++) adopt(n.childNodes[i], refs);
  }

  function syncEl(o, n, refs) {
    var i;
    for (i = o.attributes.length - 1; i >= 0; i--) {
      var an = o.attributes[i].name;
      if (!n.hasAttribute(an)) o.removeAttribute(an);
    }
    for (i = 0; i < n.attributes.length; i++) {
      var at = n.attributes[i];
      if (o.getAttribute(at.name) !== at.value) o.setAttribute(at.name, at.value);
    }
    o.__h = n.__h || {};
    for (var t in o.__h) listen(o, t);
    if (n.__value != null && o.value !== n.__value) o.value = n.__value;
    if (n.__ref) refs.push([n.__ref, o]);
    morph(o, Array.prototype.slice.call(n.childNodes), refs);
  }

  function morph(parent, next, refs) {
    var cur = Array.prototype.slice.call(parent.childNodes);
    for (var i = 0; i < next.length; i++) {
      var o = cur[i], n = next[i];
      if (!o) { parent.appendChild(n); adopt(n, refs); continue; }
      if (!sameKind(o, n)) { parent.replaceChild(n, o); adopt(n, refs); continue; }
      if (o.nodeType === 3) { if (o.data !== n.data) o.data = n.data; continue; }
      if (o.nodeType === 1) syncEl(o, n, refs);
    }
    for (var j = cur.length - 1; j >= next.length; j--) parent.removeChild(cur[j]);
  }

  function DCLogic(props) {
    this.props = props || {};
    this.state = {};
  }
  DCLogic.prototype.setState = function (p) {
    var patch = typeof p === 'function' ? p(this.state, this.props) : p;
    this.state = Object.assign({}, this.state, patch);
    if (this.__schedule) this.__schedule();
  };

  function loadClass(src) {
    /* eslint-disable no-new-func */
    return new Function('DCLogic', src + '\n;return Component;')(DCLogic);
  }

  function boot() {
    document.querySelectorAll('template[data-dc-name]').forEach(function (t) {
      var s = document.getElementById('dc-script-' + t.getAttribute('data-dc-name'));
      registry[t.getAttribute('data-dc-name')] = { tpl: t, Cls: loadClass(s ? s.textContent : 'class Component extends DCLogic{}') };
    });
    var tpl = document.getElementById('dc-tpl');
    var root = document.getElementById('dc-root');
    var Cls = loadClass(document.getElementById('dc-script').textContent);
    var inst = new Cls({});
    var pending = false, mounted = false;
    function render() {
      pending = false;
      var vals = inst.renderVals ? inst.renderVals() : {};
      var out = [];
      buildAll(kids(tpl), [vals], out);
      var refs = [];
      morph(root, out, refs);
      for (var r = 0; r < refs.length; r++) refs[r][0](refs[r][1]);
      if (!mounted) { mounted = true; if (inst.componentDidMount) inst.componentDidMount(); }
      else if (inst.componentDidUpdate) inst.componentDidUpdate();
    }
    inst.__schedule = function () {
      if (pending) return;
      pending = true;
      Promise.resolve().then(render);
    };
    render();
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
  else boot();
})();
