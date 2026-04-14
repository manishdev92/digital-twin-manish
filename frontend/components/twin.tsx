'use client';

import { useState, useRef, useEffect } from 'react';
import { Send, Bot, User } from 'lucide-react';

interface Message {
    id: string;
    role: 'user' | 'assistant';
    content: string;
    timestamp: Date;
}

export default function Twin() {
    const [messages, setMessages] = useState<Message[]>([]);
    const [input, setInput] = useState('');
    const [isLoading, setIsLoading] = useState(false);
    const [sessionId, setSessionId] = useState<string>('');
    const messagesEndRef = useRef<HTMLDivElement>(null);
    const inputRef = useRef<HTMLInputElement>(null);
    const [hasAvatar, setHasAvatar] = useState(false);

    useEffect(() => {
        fetch('/avatar.png', { method: 'HEAD' })
            .then((res) => setHasAvatar(res.ok))
            .catch(() => setHasAvatar(false));
    }, []);

    const scrollToBottom = () => {
        messagesEndRef.current?.scrollIntoView({ behavior: 'smooth' });
    };

    useEffect(() => {
        scrollToBottom();
    }, [messages]);

    const sendMessage = async () => {
        if (!input.trim() || isLoading) return;

        const userMessage: Message = {
            id: Date.now().toString(),
            role: 'user',
            content: input,
            timestamp: new Date(),
        };

        setMessages(prev => [...prev, userMessage]);
        setInput('');
        setIsLoading(true);

        const chatApiUrl =
            // process.env.NEXT_PUBLIC_CHAT_API_URL ?? 'http://localhost:8000/chat';
            `${process.env.NEXT_PUBLIC_API_URL || 'http://localhost:8000'}/chat`;
            
        try {
            const response = await fetch(chatApiUrl, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                },
                body: JSON.stringify({
                    message: userMessage.content,
                    session_id: sessionId || undefined,
                }),
            });

            const raw = await response.text();
            if (!response.ok) {
                let detail = raw.slice(0, 500);
                try {
                    const body = JSON.parse(raw) as { detail?: string | string[] };
                    if (body.detail != null) {
                        detail =
                            typeof body.detail === 'string'
                                ? body.detail
                                : body.detail.join(', ');
                    }
                } catch {
                    /* use raw slice */
                }
                if (response.status === 429) {
                    throw new Error(
                        'Amazon Bedrock: this account hit its on-demand / daily token limit (every region we tried). ' +
                            'Fix it in AWS → Service Quotas → Amazon Bedrock (search: tokens, on-demand, cross-region), ' +
                            'or wait for the limit to reset. Course FAQ: edwarddonner.com/faq (Q42).',
                    );
                }
                throw new Error(`HTTP ${response.status}: ${detail}`);
            }

            let data: { response?: string; session_id?: string };
            try {
                data = JSON.parse(raw) as { response?: string; session_id?: string };
            } catch {
                throw new Error(`Expected JSON from API; got: ${raw.slice(0, 120)}…`);
            }

            if (!sessionId && data.session_id) {
                setSessionId(data.session_id);
            }

            const assistantMessage: Message = {
                id: (Date.now() + 1).toString(),
                role: 'assistant',
                content: data.response ?? '(No response field in JSON)',
                timestamp: new Date(),
            };

            setMessages(prev => [...prev, assistantMessage]);
        } catch (error) {
            console.error('Error:', error);
            const msg =
                error instanceof TypeError
                    ? 'Network or CORS blocked this request. In API Gateway → CORS, add the exact origin from your address bar (e.g. https://….cloudfront.net), no trailing slash. If OPTIONS hits Lambda, match CORS_ORIGINS there too. See week2 day2 Part 7 Step 6.'
                    : error instanceof Error
                      ? error.message
                      : 'Sorry, I encountered an error. Please try again.';
            const errorMessage: Message = {
                id: (Date.now() + 1).toString(),
                role: 'assistant',
                content: msg,
                timestamp: new Date(),
            };
            setMessages(prev => [...prev, errorMessage]);
        } finally {
            setIsLoading(false);
            setTimeout(() => inputRef.current?.focus(), 100);
        }
    };

    const handleKeyPress = (e: React.KeyboardEvent) => {
        if (e.key === 'Enter' && !e.shiftKey) {
            e.preventDefault();
            sendMessage();
        }
    };

    return (
        <div className="flex flex-col h-full bg-gray-50 rounded-lg shadow-lg">
            {/* Header */}
            <div className="bg-gradient-to-r from-slate-700 to-slate-800 text-white p-4 rounded-t-lg">
                <h2 className="text-xl font-semibold flex items-center gap-2">
                    <Bot className="w-6 h-6" />
                    AI Digital Twin
                </h2>
                <p className="text-sm text-slate-300 mt-1">Your AI course companion</p>
            </div>

            {/* Messages */}
            <div className="flex-1 overflow-y-auto p-4 space-y-4">
                {messages.length === 0 && (
                    <div className="text-center text-gray-500 mt-8">
                        {hasAvatar ? (
                            <img
                                src="/avatar.png"
                                alt="Digital Twin Avatar"
                                className="w-20 h-20 rounded-full mx-auto mb-3 border-2 border-gray-300"
                            />
                        ) : (
                            <Bot className="w-12 h-12 mx-auto mb-3 text-gray-400" />
                        )}
                        <p>Hello! I&apos;m your Digital Twin.</p>
                        <p className="text-sm mt-2">Ask me anything about AI deployment!</p>
                    </div>
                )}

                {messages.map((message) => (
                    <div
                        key={message.id}
                        className={`flex gap-3 ${
                            message.role === 'user' ? 'justify-end' : 'justify-start'
                        }`}
                    >
                        {message.role === 'assistant' && (
                            <div className="flex-shrink-0">
                                {hasAvatar ? (
                                    <img
                                        src="/avatar.png"
                                        alt="Digital Twin Avatar"
                                        className="w-8 h-8 rounded-full border border-slate-300"
                                    />
                                ) : (
                                    <div className="w-8 h-8 bg-slate-700 rounded-full flex items-center justify-center">
                                        <Bot className="w-5 h-5 text-white" />
                                    </div>
                                )}
                            </div>
                        )}

                        <div
                            className={`max-w-[70%] rounded-lg p-3 ${
                                message.role === 'user'
                                    ? 'bg-slate-700 text-white'
                                    : 'bg-white border border-gray-200 text-gray-800'
                            }`}
                        >
                            <p className="whitespace-pre-wrap">{message.content}</p>
                            <p
                                className={`text-xs mt-1 ${
                                    message.role === 'user' ? 'text-slate-300' : 'text-gray-500'
                                }`}
                            >
                                {message.timestamp.toLocaleTimeString()}
                            </p>
                        </div>

                        {message.role === 'user' && (
                            <div className="flex-shrink-0">
                                <div className="w-8 h-8 bg-gray-600 rounded-full flex items-center justify-center">
                                    <User className="w-5 h-5 text-white" />
                                </div>
                            </div>
                        )}
                    </div>
                ))}

                {isLoading && (
                    <div className="flex gap-3 justify-start">
                        <div className="flex-shrink-0">
                            {hasAvatar ? (
                                <img
                                    src="/avatar.png"
                                    alt="Digital Twin Avatar"
                                    className="w-8 h-8 rounded-full border border-slate-300"
                                />
                            ) : (
                                <div className="w-8 h-8 bg-slate-700 rounded-full flex items-center justify-center">
                                    <Bot className="w-5 h-5 text-white" />
                                </div>
                            )}
                        </div>
                        <div className="bg-white border border-gray-200 rounded-lg p-3">
                            <div className="flex space-x-2">
                                <div className="w-2 h-2 bg-gray-400 rounded-full animate-bounce" />
                                <div className="w-2 h-2 bg-gray-400 rounded-full animate-bounce delay-100" />
                                <div className="w-2 h-2 bg-gray-400 rounded-full animate-bounce delay-200" />
                            </div>
                        </div>
                    </div>
                )}

                <div ref={messagesEndRef} />
            </div>

            {/* Input */}
            <div className="border-t border-gray-200 p-4 bg-white rounded-b-lg">
                <div className="flex gap-2">
                    <input
                        ref={inputRef}
                        type="text"
                        value={input}
                        onChange={(e) => setInput(e.target.value)}
                        onKeyDown={handleKeyPress}
                        placeholder="Type your message..."
                        className="flex-1 px-4 py-2 border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-slate-600 focus:border-transparent text-gray-800"
                        disabled={isLoading}
                        autoFocus
                    />
                    <button
                        onClick={sendMessage}
                        disabled={!input.trim() || isLoading}
                        className="px-4 py-2 bg-slate-700 text-white rounded-lg hover:bg-slate-800 focus:outline-none focus:ring-2 focus:ring-slate-600 disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
                    >
                        <Send className="w-5 h-5" />
                    </button>
                </div>
            </div>
        </div>
    );
}