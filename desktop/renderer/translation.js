export const PROVIDERS = {
  'ChatGPT (OpenAI)': {
    endpoint: 'https://api.openai.com/v1/chat/completions',
    defaultModel: 'gpt-4o-mini',
    placeholder: 'sk-...',
    style: 'openai',
    storeKey: 'openai',
  },
  'Claude (Anthropic)': {
    endpoint: 'https://api.anthropic.com/v1/messages',
    defaultModel: 'claude-3-5-haiku-latest',
    placeholder: 'sk-ant-...',
    style: 'claude',
    storeKey: 'anthropic',
  },
  OpenRouter: {
    endpoint: 'https://openrouter.ai/api/v1/chat/completions',
    defaultModel: 'openai/gpt-4o-mini',
    placeholder: 'sk-or-...',
    style: 'openrouter',
    storeKey: 'openrouter',
  },
  'Grok (xAI)': {
    endpoint: 'https://api.x.ai/v1/chat/completions',
    defaultModel: 'grok-3-mini',
    placeholder: 'xai-...',
    style: 'openai',
    storeKey: 'xai',
  },
};

export function parseNumbered(text, count) {
  const result = [];
  for (const line of String(text).split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    const m = trimmed.match(/^\d+[.、)]\s*/);
    if (m) {
      result.push(trimmed.slice(m[0].length));
    } else if (result.length) {
      result[result.length - 1] += ` ${trimmed}`;
    } else {
      result.push(trimmed);
    }
  }
  while (result.length < count) result.push('');
  return result.slice(0, count);
}

async function chat({ provider, apiKey, model, prompt, maxTokens, timeoutMs }) {
  const meta = PROVIDERS[provider] || PROVIDERS['ChatGPT (OpenAI)'];
  const headers = { 'Content-Type': 'application/json' };
  const resolvedMaxTokens = maxTokens || 8192;
  const resolvedTimeout = timeoutMs || 60000;
  let body;

  if (meta.style === 'claude') {
    headers['x-api-key'] = apiKey;
    headers['anthropic-version'] = '2023-06-01';
    body = {
      model,
      max_tokens: resolvedMaxTokens,
      messages: [{ role: 'user', content: prompt }],
    };
  } else {
    headers.Authorization = `Bearer ${apiKey}`;
    if (meta.style === 'openrouter') {
      headers['X-Title'] = 'TranslateBrowser/1.0';
    }
    body = {
      model,
      max_tokens: resolvedMaxTokens,
      messages: [{ role: 'user', content: prompt }],
    };
  }

  const payload = JSON.stringify(body);
  let status;
  let raw;
  if (window.tbDesktop?.translate) {
    const result = await window.tbDesktop.translate({
      url: meta.endpoint,
      headers,
      body: payload,
      timeoutMs: resolvedTimeout,
    });
    status = result?.status ?? -1;
    raw = result?.body || '';
    if (!result?.ok) {
      throw new Error(`HTTP ${status}: ${raw.slice(0, 300)}`);
    }
  } else {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), resolvedTimeout);
    let res;
    try {
      res = await fetch(meta.endpoint, {
        method: 'POST',
        headers,
        body: payload,
        signal: controller.signal,
      });
    } finally {
      clearTimeout(timer);
    }
    status = res.status;
    raw = await res.text();
    if (!res.ok) {
      throw new Error(`HTTP ${status}: ${raw.slice(0, 300)}`);
    }
  }
  const json = JSON.parse(raw);
  let content = '';
  if (meta.style === 'claude') {
    content = json?.content?.[0]?.text || '';
  } else {
    content = json?.choices?.[0]?.message?.content || '';
  }
  if (!content) throw new Error('模型返回为空');
  return content;
}

/**
 * Translate 1-2 cues with a simpler prompt for lower latency (realtime mode).
 */
export async function translateLive({ provider, apiKey, model, texts, targetLang }) {
  const meta = PROVIDERS[provider] || PROVIDERS['ChatGPT (OpenAI)'];
  const resolvedModel = model || meta.defaultModel;
  const count = texts.length;
  const maxTokens = count <= 1 ? 256 : 512;
  const timeoutMs = 20000;

  let prompt;
  if (count === 1) {
    prompt = `翻译成${targetLang}，只输出译文，不要解释：\n${texts[0]}`;
  } else {
    const numbered = texts.map((t, i) => `${i + 1}. ${String(t).replace(/\n/g, ' ')}`).join('\n');
    prompt = `将下列字幕逐条翻译成${targetLang}。只输出翻译，保留编号，每行一条：\n\n${numbered}`;
  }

  const reply = await chat({
    provider,
    apiKey,
    model: resolvedModel,
    prompt,
    maxTokens,
    timeoutMs,
  });

  if (count === 1) {
    return [reply.trim()];
  }
  return parseNumbered(reply, count);
}

export async function translateTexts({ provider, apiKey, model, texts, targetLang }) {
  const meta = PROVIDERS[provider] || PROVIDERS['ChatGPT (OpenAI)'];
  const resolvedModel = model || meta.defaultModel;
  const isSmall = texts.length <= 3;
  const timeoutMs = isSmall ? 20000 : 60000;
  const maxTokens = isSmall ? 512 : 8192;

  const numbered = texts
    .map((t, i) => `${i + 1}. ${String(t).replace(/\n/g, ' ')}`)
    .join('\n');
  const prompt = `将下列字幕逐条翻译成${targetLang}。要求：只输出翻译，保留原有编号（格式为"编号. 译文"），每行一条，不要合并、不要解释。\n\n${numbered}`;

  let lastError = null;
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const reply = await chat({
        provider,
        apiKey,
        model: resolvedModel,
        prompt,
        maxTokens,
        timeoutMs,
      });
      const parsed = parseNumbered(reply, texts.length);
      const nonEmpty = parsed.filter((x) => x).length;
      if (nonEmpty >= Math.max(1, Math.floor(texts.length / 2)) || attempt === 1) {
        return parsed;
      }
    } catch (err) {
      lastError = err;
      if (attempt === 1) throw err;
    }
  }
  if (lastError) throw lastError;
  return Array(texts.length).fill('');
}
