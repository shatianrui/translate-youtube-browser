export const PROVIDERS = {
  'ChatGPT (OpenAI)': {
    endpoint: 'https://api.openai.com/v1/chat/completions',
    defaultModel: 'gpt-4o-mini',
    placeholder: 'sk-...',
    style: 'openai',
  },
  'Claude (Anthropic)': {
    endpoint: 'https://api.anthropic.com/v1/messages',
    defaultModel: 'claude-3-5-haiku-latest',
    placeholder: 'sk-ant-...',
    style: 'claude',
  },
  OpenRouter: {
    endpoint: 'https://openrouter.ai/api/v1/chat/completions',
    defaultModel: 'openai/gpt-4o-mini',
    placeholder: 'sk-or-...',
    style: 'openrouter',
  },
  'Grok (xAI)': {
    endpoint: 'https://api.x.ai/v1/chat/completions',
    defaultModel: 'grok-3-mini',
    placeholder: 'xai-...',
    style: 'openai',
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

async function chat({ provider, apiKey, model, prompt }) {
  const meta = PROVIDERS[provider] || PROVIDERS['ChatGPT (OpenAI)'];
  const headers = { 'Content-Type': 'application/json' };
  let body;

  if (meta.style === 'claude') {
    headers['x-api-key'] = apiKey;
    headers['anthropic-version'] = '2023-06-01';
    body = {
      model,
      max_tokens: 8192,
      messages: [{ role: 'user', content: prompt }],
    };
  } else {
    headers.Authorization = `Bearer ${apiKey}`;
    if (meta.style === 'openrouter') {
      headers['X-Title'] = 'TranslateBrowser/1.0';
    }
    body = {
      model,
      messages: [{ role: 'user', content: prompt }],
    };
  }

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 60000);
  let res;
  try {
    res = await fetch(meta.endpoint, {
      method: 'POST',
      headers,
      body: JSON.stringify(body),
      signal: controller.signal,
    });
  } finally {
    clearTimeout(timer);
  }

  const raw = await res.text();
  if (!res.ok) {
    throw new Error(`HTTP ${res.status}: ${raw.slice(0, 300)}`);
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

export async function translateTexts({ provider, apiKey, model, texts, targetLang }) {
  const meta = PROVIDERS[provider] || PROVIDERS['ChatGPT (OpenAI)'];
  const resolvedModel = model || meta.defaultModel;
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
