/**
 * About DataAgent markdown content. Inlined to avoid raw-loader dependency
 * (Turbopack cannot resolve raw-loader for .md imports).
 */
export const aboutMarkdown = `# DataAgent

DataAgent 是一个基于 LangGraph 的数据分析智能体平台。

---

## 核心功能

* **智能数据分析**：自然语言驱动的 SQL 查询与数据探索
* **多数据源支持**：支持跨实例查询与多数据源整合
* **Python 沙箱**：安全执行代码生成图表、报表和文件
* **知识库检索**：向量检索驱动的指标定义和业务术语查询
* **会话持久化**：对话历史和上下文记忆

---

## 技术栈

- **[LangChain](https://github.com/langchain-ai/langchain)**: LLM 交互框架
- **[LangGraph](https://github.com/langchain-ai/langgraph)**: 多智能体编排
- **[Next.js](https://nextjs.org/)**: Web 应用框架
- **[FastAPI](https://fastapi.tiangolo.com/)**: 后端 API 框架
`;
