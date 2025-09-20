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

const splitIntoChunks = (text, chunkSize = 5000) => {
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
  return chunks.splice(0, 5);
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

const extractJsonFromResponse = (response) => {
  try {
    // Get the content from the response
    const content = response.message.content;

    // Find JSON content between markdown code blocks
    const jsonMatch = content.match(/```(?:json)?\s*([\s\S]*?)\s*```/);

    if (jsonMatch && jsonMatch[1]) {
      // Parse the extracted JSON string
      const jsonString = jsonMatch[1].trim();
      return JSON.parse(jsonString);
    } else {
      // If no markdown code blocks, try to find JSON directly
      const possibleJson = content.match(/\{[\s\S]*\}/);
      if (possibleJson) {
        return JSON.parse(possibleJson[0]);
      }
      throw new Error("No JSON found in response");
    }
  } catch (error) {
    console.error("Error extracting JSON:", error);
    return null;
  }
};

// Final analysis using extracted data
const getProjectHealthAnalysis = async (jiraMetrics, confluenceMetrics) => {
  return await ollama.chat({
    model: "gemma3:1b",
    messages: [
      {
        role: "system",
        content: "Create a project health analysis in JSON format that can be parsed with JSON.parse",
      },
      { role: "user", content: `Jira metrics: ${jiraMetrics}` },
      { role: "user", content: `Confluence metrics: ${confluenceMetrics}` },
      {
        role: "user",
        content: `Based on these metrics, this project health analysis of given JSON format type don't add any comment inside json I need clean json which can be easilty parsed by JSON.parse:
        {
          "projectHealth": "GREEN|YELLOW|RED",
          "score": 0-100, // Overall project health score
          "metrics": {
            "velocity": number // Number representing team velocity,
            "issueStatus": {
              "open": number, // Number of open issues
              "inProgress": number, // Number of issues in progress
              "closed": number // Number of closed issues
            },
            "teamPerformance": {
                "engagement": 78, // Team engagement score out of 100
                "satisfaction": 72, // Team satisfaction score out of 100
                "velocity": 75 // Team velocity score out of 100
            },
            projectRiskFactors: { // Overall project risk factors
                "risk1": {
                    "description": "Description of the risk factor",
                    "impact": "HIGH|MEDIUM|LOW", // Impact level of the risk
                    "mitigationStatus": "NOT_STARTED|IN_PROGRESS|COMPLETED" // Current status of risk mitigation
                }
            }[] // List of overall project risk factors
            ,
            "milestones": {
                "title": "Milestone 1",
                "description": "Description of Milestone 1",
                "status": "GREEN"|"YELLOW"|"RED", // status of the milestone based on due date and completion percentage
                "completionPercentage": number, // percentage of tasks completed for the milestone
                "dueDate": "2023-10-01", // due date of the milestone
                "velocity": number // velocity of the team related to this milestone,
                "riskFactors": { // Milestone risk factors
                    "risk1": {
                        "description": "Description of the risk factor",
                        "impact": "HIGH|MEDIUM|LOW", // Impact level of the risk
                        "mitigationStatus": "NOT_STARTED|IN_PROGRESS|COMPLETED" // Current status of risk mitigation
                    }
                }[] // List of risk factors affecting this milestone
            }[],
            "recommendations": {
                "title": "Recommendation 1",
                "description": "Description of recommendation 1",
                "status": "NOT_STARTED|IN_PROGRESS|COMPLETED"
            }[],
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

app.get("/api/project-health", async (req, res) => {
  try {
    // Read data files
    const jiraData = fs.readFileSync("./fetches/scripts/jira_epic_data.txt", "utf-8");
    const confluenceData = fs.readFileSync("./fetches/scripts/confluence_documents_data.txt", "utf-8");

    // Split into manageable chunks
    const jiraChunks = splitIntoChunks(jiraData);
    const confluenceChunks = splitIntoChunks(confluenceData);

    // Extract metrics from each chunk
    const jiraMetrics = await extractMetricsFromChunks(jiraChunks, "Jira");
    const confluenceMetrics = await extractMetricsFromChunks(confluenceChunks, "Confluence");

    // Final analysis using the extracted metrics
    const aiResponse = await getProjectHealthAnalysis(jiraMetrics, confluenceMetrics);

    res.send(extractJsonFromResponse(aiResponse));
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
