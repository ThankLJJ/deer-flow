import { redirect } from "next/navigation";

export default function LandingPage() {
  // 直接跳转到 workspace，不显示 DeerFlow 宣传页
  redirect("/workspace/chats/new");
}
