// routes/products.js
import express from "express";
import { body } from "express-validator";
import {
  createProduct,
  getProducts,
  getProductById,
  updateProduct,
  deleteProduct,
} from "../controllers/productController.js";

const router = express.Router();

// Create
router.post(
  "/",
  [
    body("name").notEmpty().withMessage("Name required"),
    body("price").isNumeric().withMessage("Price must be a number"),
  ],
  createProduct
);

// Read all
router.get("/", getProducts);

// Read one
router.get("/:id", getProductById);

// Update
router.put("/:id", updateProduct);

// Delete
router.delete("/:id", deleteProduct);

export default router;
