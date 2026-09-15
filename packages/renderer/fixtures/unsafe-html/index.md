---
title: Unsafe input
---

## Safe heading

<script>alert("removed")</script>

<img src="images/unsafe.png" alt="Unsafe" onerror="alert(1)">

[Unsafe link](javascript:alert(1))

<svg><script>alert(2)</script><circle cx="5" cy="5" r="5"></circle></svg>

<iframe src="https://evil.example/embed/123" onclick="alert(3)"></iframe>

<iframe src="https://www.youtube-nocookie.com/embed/abc-123?start=10" title="Allowed video" width="560" height="315" allowfullscreen class="removed"></iframe>
