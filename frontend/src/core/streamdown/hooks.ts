"use client";

import { useEffect, useState } from "react";
import type { StreamdownProps } from "streamdown";

import {
  getStreamdownPlugins,
  getStreamdownPluginsWithWordAnimation,
  getHumanMessagePlugins,
  preloadKatex,
} from "./plugins";

type PluginSet = {
  remarkPlugins: StreamdownProps["remarkPlugins"];
  rehypePlugins: StreamdownProps["rehypePlugins"];
};

const DEFAULT_PLUGINS: PluginSet = {
  remarkPlugins: [],
  rehypePlugins: [],
};

/** Hook that lazily loads streamdown plugins with katex. */
export function useStreamdownPlugins() {
  const [plugins, setPlugins] = useState<PluginSet>(DEFAULT_PLUGINS);

  useEffect(() => {
    getStreamdownPlugins().then(setPlugins);
  }, []);

  return plugins;
}

/** Hook that lazily loads streamdown plugins with word animation + katex. */
export function useStreamdownPluginsWithWordAnimation() {
  const [plugins, setPlugins] = useState<PluginSet>(DEFAULT_PLUGINS);

  useEffect(() => {
    getStreamdownPluginsWithWordAnimation().then(setPlugins);
  }, []);

  return plugins;
}

/** Hook that lazily loads human message plugins with katex. */
export function useHumanMessagePlugins() {
  const [plugins, setPlugins] = useState<PluginSet>(DEFAULT_PLUGINS);

  useEffect(() => {
    getHumanMessagePlugins().then(setPlugins);
  }, []);

  return plugins;
}

/** Preload katex module - call early in the app lifecycle. */
export { preloadKatex };
