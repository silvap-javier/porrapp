"use client";

import { useEffect, useMemo, useRef, useState, useTransition } from "react";
import { useTranslations } from "next-intl";
import { createClient } from "@/lib/supabase/client";
import { sendMessage, type ChatMessage } from "@/lib/chat-actions";

type Member = { id: string; name: string };

function escapeRe(s: string) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

export default function ChatTab({
  leagueId,
  currentUserId,
  members,
  initialMessages,
}: {
  leagueId: string;
  currentUserId: string;
  members: Member[];
  initialMessages: ChatMessage[];
}) {
  const t = useTranslations("chat");
  const tErr = useTranslations("errors");
  const [messages, setMessages] = useState<ChatMessage[]>(initialMessages);
  const [text, setText] = useState("");
  const [error, setError] = useState("");
  const [isPending, startTransition] = useTransition();
  const bottomRef = useRef<HTMLDivElement>(null);

  const nameOf = useMemo(() => {
    const m = new Map(members.map((x) => [x.id, x.name]));
    return (id: string) => m.get(id) ?? "—";
  }, [members]);

  const myName = nameOf(currentUserId);

  // Regex para resaltar menciones por nombre de miembro (de mayor a menor longitud).
  const mentionRe = useMemo(() => {
    const names = members.map((x) => x.name).filter(Boolean).sort((a, b) => b.length - a.length);
    if (!names.length) return null;
    return new RegExp(`@(${names.map(escapeRe).join("|")})`, "g");
  }, [members]);

  const append = (msg: ChatMessage) =>
    setMessages((prev) => (prev.some((m) => m.id === msg.id) ? prev : [...prev, msg]));

  // Realtime
  useEffect(() => {
    const supabase = createClient();
    const channel = supabase
      .channel(`league-chat-${leagueId}`)
      .on(
        "postgres_changes",
        { event: "INSERT", schema: "public", table: "league_messages", filter: `league_id=eq.${leagueId}` },
        (payload) => append(payload.new as ChatMessage)
      )
      .subscribe();
    return () => {
      supabase.removeChannel(channel);
    };
  }, [leagueId]);

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [messages]);

  // Autocompletado de @
  const [mentionQuery, setMentionQuery] = useState<string | null>(null);
  const onChange = (v: string) => {
    setText(v);
    const m = v.match(/@([\p{L}0-9_]*)$/u);
    setMentionQuery(m ? m[1].toLowerCase() : null);
  };
  const suggestions =
    mentionQuery !== null
      ? members.filter((x) => x.name.toLowerCase().startsWith(mentionQuery)).slice(0, 5)
      : [];
  const pickMention = (name: string) => {
    setText((prev) => prev.replace(/@([\p{L}0-9_]*)$/u, `@${name} `));
    setMentionQuery(null);
  };

  const send = () => {
    const body = text.trim();
    if (!body) return;
    setError("");
    startTransition(async () => {
      const res = await sendMessage(leagueId, body);
      if ("error" in res) {
        setError(tErr(res.error));
        return;
      }
      append(res.message);
      setText("");
      setMentionQuery(null);
    });
  };

  const renderBody = (body: string) => {
    if (!mentionRe) return body;
    const parts: (string | { m: string })[] = [];
    let last = 0;
    body.replace(mentionRe, (match, _name, offset: number) => {
      if (offset > last) parts.push(body.slice(last, offset));
      parts.push({ m: match });
      last = offset + match.length;
      return match;
    });
    if (last < body.length) parts.push(body.slice(last));
    return parts.map((p, i) =>
      typeof p === "string" ? (
        <span key={i}>{p}</span>
      ) : (
        <span key={i} className="font-semibold text-primary">{p.m}</span>
      )
    );
  };

  const timeFmt = (iso: string) =>
    new Date(iso).toLocaleTimeString("es-ES", { hour: "2-digit", minute: "2-digit" });

  return (
    <div className="flex flex-col" style={{ minHeight: "60vh" }}>
      <div className="flex-1 space-y-2 pb-2">
        {messages.length === 0 ? (
          <p className="text-sm text-muted text-center py-8">{t("empty")}</p>
        ) : (
          messages.map((m) => {
            const mine = m.user_id === currentUserId;
            const mentionsMe = myName && m.body.includes(`@${myName}`);
            return (
              <div key={m.id} className={`flex ${mine ? "justify-end" : "justify-start"}`}>
                <div
                  className={`max-w-[80%] rounded-2xl px-3 py-2 ${
                    mine ? "bg-primary text-white" : "bg-surface border border-border text-foreground"
                  } ${mentionsMe && !mine ? "ring-2 ring-accent" : ""}`}
                >
                  {!mine && (
                    <p className="text-[11px] font-semibold text-secondary mb-0.5">{nameOf(m.user_id)}</p>
                  )}
                  <p className="text-sm whitespace-pre-wrap break-words leading-snug">
                    {renderBody(m.body)}
                  </p>
                  <p className={`text-[10px] mt-0.5 ${mine ? "text-white/70" : "text-muted"}`}>
                    {timeFmt(m.created_at)}
                  </p>
                </div>
              </div>
            );
          })
        )}
        <div ref={bottomRef} />
      </div>

      {/* Input */}
      <div className="sticky bottom-0 bg-background pt-2">
        {suggestions.length > 0 && (
          <div className="mb-1 bg-surface border border-border rounded-xl overflow-hidden">
            {suggestions.map((s) => (
              <button
                key={s.id}
                onClick={() => pickMention(s.name)}
                className="w-full text-left px-3 py-2 text-sm hover:bg-surface-hover"
              >
                @{s.name}
              </button>
            ))}
          </div>
        )}
        <div className="flex items-end gap-2">
          <textarea
            value={text}
            onChange={(e) => onChange(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter" && !e.shiftKey) {
                e.preventDefault();
                send();
              }
            }}
            rows={1}
            placeholder={t("placeholder")}
            className="flex-1 resize-none px-4 py-2.5 rounded-2xl border border-border bg-surface focus:outline-none focus:ring-2 focus:ring-primary/50 max-h-32"
          />
          <button
            onClick={send}
            disabled={isPending || !text.trim()}
            className="flex-shrink-0 bg-primary text-white w-10 h-10 rounded-full font-medium hover:bg-primary-dark transition-colors disabled:opacity-40"
          >
            ➤
          </button>
        </div>
        {error && <p className="text-xs text-red-600 mt-1">{error}</p>}
      </div>
    </div>
  );
}
