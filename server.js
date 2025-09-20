// server.js
import "dotenv/config";
import ollama from "ollama";
import fs from "fs";
import express from "express";
import morgan from "morgan";
import helmet from "helmet";
import cors from "cors";

import connectDB from "./config/db.js";
import productRoutes from "./routes/products.js";
import projectHealthRoutes from "./routes/projectHealth.js";

import { notFound, errorHandler } from "./middleware/errorMiddleware.js";

const app = express();
const PORT = process.env.PORT || 5000;

// Connect to DB
connectDB(process.env.MONGODB_URI);

// Middleware
if (process.env.NODE_ENV === "development") {
  app.use(morgan("dev"));
}

const splitIntoChunks = (text, chunkSize = 2000) => {
  const chunks = [];
  let i = 0;
  while (i < text.length) {
    // Find a good breaking point near the chunk size
    let end = Math.min(i + chunkSize, text.length);
    if (end < text.length) {
      const possibleEnd = text.substring(i, end).search(/[.!?][\s\n]/g);
      if (possibleEnd !== -1) {
        end = i + possibleEnd + 2;
      }
    }
    chunks.push(text.substring(i, end));
    i = end;
  }
  // to do remove this
  return chunks;
};

// Extract metrics from each chunk
const extractMetricsFromChunks = async (chunks, dataType) => {
  const extractedData = [];

  for (const [index, chunk] of chunks.entries()) {
    console.log(`Processing ${dataType} chunk ${index + 1}/${chunks.length}`);
    const response = await ollama.chat({
      model: "gemma3:1b",
      messages: [
        {
          role: "system",
          content: `Extract key project health metrics from this ${dataType} data chunk. Focus on quantitative data.`,
        },
        { role: "user", content: chunk },
      ],
    });
    extractedData.push(response.message.content);
  }
  return extractedData.join("\n\n");
};

// Final analysis using extracted data
const getProjectHealthAnalysis = async (jiraMetrics, confluenceMetrics) => {
  return await ollama.chat({
    model: "gemma3:1b",
    messages: [
      {
        role: "system",
        content:
          "Create a project health analysis in JSON format that can be parsed with JSON.parse",
      },
      { role: "user", content: `Jira metrics: ${jiraMetrics}` },
      { role: "user", content: `Confluence metrics: ${confluenceMetrics}` },
      {
        role: "user",
        content: `Based on these metrics, provide a project health analysis in this JSON format:
        {
          "projectHealth": "GREEN|YELLOW|RED",
          "score": 0-100,
          "metrics": {
            "velocity": {...},
            "issueStatus": {...},
            "risks": [...],
            "recommendations": [...]
          },
          "analysis": "summary text"
        }`,
      },
    ],
  });
};

app.use(helmet());
app.use(cors());
app.use(express.json()); // body parser

// Routes
app.use("/api/products", productRoutes);

app.get("/api/project", async (req, res) => {
  try {
    // Read data files
    // const jiraData = fs.readFileSync(
    //   "./ruby_server/jira_board_data.txt",
    //   "utf-8"
    // );
    const confluenceData = fs.readFileSync("./confluence.txt", "utf-8");

    // Split into manageable chunks
    // const jiraChunks = splitIntoChunks(jiraData);
    const confluenceChunks = splitIntoChunks(confluenceData);

    // Extract metrics from each chunk
    // const jiraMetrics = await extractMetricsFromChunks(jiraChunks, "Jira");
    const confluenceMetrics = await extractMetricsFromChunks(
      confluenceChunks,
      "Confluence"
    );

    // Final analysis using the extracted metrics
    const aiResponse = await getProjectHealthAnalysis(
      //   jiraMetrics,
      "hello",
      confluenceMetrics
    );

    res.send(aiResponse);
  } catch (error) {
    console.error("Error analyzing project health:", error);
    res.status(500).send({ error: "Failed to analyze project health" });
  }
});

app.use("/api/project-health", projectHealthRoutes);

// Health check
app.get("/", (req, res) => res.send("API running"));

// Error handling
app.use(notFound);
app.use(errorHandler);

app.listen(PORT, () => {
  console.log(`Server running in ${process.env.NODE_ENV} mode on port ${PORT}`);
});
